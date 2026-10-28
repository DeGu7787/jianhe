#include "native_ball_window.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <utility>

#include "resource.h"

namespace {

constexpr wchar_t kBallWindowClassName[] = L"JIANHE_NATIVE_BALL_WINDOW";
constexpr double kLogicalBallSize = 72.0;
constexpr double kLogicalBallMargin = 8.0;
constexpr BYTE kIdleWindowAlpha = 122;
constexpr BYTE kHoverWindowAlpha = 255;

const uint32_t* MainBallPixels() {
  static const uint32_t* pixels = []() -> const uint32_t* {
    HMODULE module = GetModuleHandle(nullptr);
    HRSRC resource =
        FindResource(module, MAKEINTRESOURCE(IDR_MAIN_BALL_BGRA), RT_RCDATA);
    if (!resource || SizeofResource(module, resource) != 72 * 72 * 4) {
      return nullptr;
    }
    HGLOBAL loaded = LoadResource(module, resource);
    return loaded
               ? static_cast<const uint32_t*>(LockResource(loaded))
               : nullptr;
  }();
  return pixels;
}

ATOM RegisterBallWindowClass() {
  static ATOM window_class = 0;
  if (window_class != 0) {
    return window_class;
  }

  WNDCLASS definition{};
  definition.hCursor = LoadCursor(nullptr, IDC_HAND);
  definition.lpszClassName = kBallWindowClassName;
  definition.hInstance = GetModuleHandle(nullptr);
  definition.lpfnWndProc = NativeBallWindow::WndProc;
  definition.hbrBackground = nullptr;
  window_class = RegisterClass(&definition);
  return window_class;
}

double Clamp01(double value) {
  return std::clamp(value, 0.0, 1.0);
}

double CircleCoverage(double x,
                      double y,
                      double center_x,
                      double center_y,
                      double radius,
                      double antialias_width) {
  const double distance = std::hypot(x - center_x, y - center_y);
  return Clamp01((radius - distance) / antialias_width + 0.5);
}

void BlendPixel(uint32_t* pixel,
                BYTE red,
                BYTE green,
                BYTE blue,
                double coverage) {
  const int source_alpha =
      static_cast<int>(std::round(255.0 * Clamp01(coverage)));
  if (source_alpha == 0) {
    return;
  }

  const int destination_blue = *pixel & 0xFF;
  const int destination_green = (*pixel >> 8) & 0xFF;
  const int destination_red = (*pixel >> 16) & 0xFF;
  const int destination_alpha = (*pixel >> 24) & 0xFF;
  const int inverse_alpha = 255 - source_alpha;

  const int output_alpha =
      source_alpha + destination_alpha * inverse_alpha / 255;
  const int output_red =
      red * source_alpha / 255 + destination_red * inverse_alpha / 255;
  const int output_green =
      green * source_alpha / 255 + destination_green * inverse_alpha / 255;
  const int output_blue =
      blue * source_alpha / 255 + destination_blue * inverse_alpha / 255;

  *pixel = (output_alpha << 24) | (output_red << 16) |
           (output_green << 8) | output_blue;
}

}  // namespace

NativeBallWindow::NativeBallWindow() = default;

NativeBallWindow::~NativeBallWindow() {
  Destroy();
}

bool NativeBallWindow::Create(HWND host_window, EventCallback callback) {
  host_window_ = host_window;
  callback_ = std::move(callback);
  dpi_ = GetDpiForWindow(host_window_);

  if (!RegisterBallWindowClass()) {
    return false;
  }

  const int size =
      static_cast<int>(std::round(kLogicalBallSize * dpi_ / 96.0));
  window_ = CreateWindowEx(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE,
      kBallWindowClassName, L"Jianhe Native Ball", WS_POPUP, 0, 0, size, size,
      nullptr,
      nullptr, GetModuleHandle(nullptr), this);
  if (!window_) {
    return false;
  }

  PositionForHost();
  Render();
  // Periodic Z-order guard: the Flutter host window can be re-raised above
  // the ball by async engine/OS activity after a resize. Re-asserting
  // TOPMOST here (a cheap no-op when already on top) keeps the ball always
  // clickable.
  SetTimer(window_, 1, 250, nullptr);
  return true;
}

void NativeBallWindow::Destroy() {
  if (window_) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
  callback_ = nullptr;
}

void NativeBallWindow::Show() {
  if (window_) {
    SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  }
}

void NativeBallWindow::PositionForHost() {
  if (!window_ || !host_window_) {
    return;
  }

  RECT host{};
  GetWindowRect(host_window_, &host);
  const bool first_position = !positioned_once_;
  HMONITOR monitor = nullptr;
  if (first_position) {
    const POINT primary_monitor_point{0, 0};
    monitor =
        MonitorFromPoint(primary_monitor_point, MONITOR_DEFAULTTOPRIMARY);
  } else {
    monitor = MonitorFromRect(&host, MONITOR_DEFAULTTONEAREST);
  }

  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  if (!monitor || !GetMonitorInfo(monitor, &monitor_info)) {
    return;
  }
  const RECT work = monitor_info.rcWork;

  dpi_ = GetDpiForWindow(host_window_);
  const double scale = dpi_ / 96.0;
  const int host_width = host.right - host.left;
  const int host_height = host.bottom - host.top;
  const int margin = static_cast<int>(std::round(kLogicalBallMargin * scale));
  const int size = static_cast<int>(std::round(kLogicalBallSize * scale));
  const bool vertical_edge =
      edge_ == BallDockEdge::kLeft || edge_ == BallDockEdge::kRight;
  const int min_along = margin + size / 2;
  const int extent = vertical_edge ? (work.bottom - work.top)
                                   : (work.right - work.left);
  const int max_along = std::max(min_along, extent - min_along);

  if (first_position) {
    // First placement: center the ball along the initial edge.
    offset_ = extent / 2.0 / scale;
  }
  const int along = std::clamp(
      static_cast<int>(std::round(offset_ * scale)), min_along, max_along);

  // Dock the host flush against the edge and center the ball's along-axis
  // position on the requested offset. The host is clamped to the work area so
  // it can never be dragged off-screen.
  int host_x = host.left;
  int host_y = host.top;
  switch (edge_) {
    case BallDockEdge::kLeft:
      host_x = work.left;
      host_y = work.top + along - host_height / 2;
      break;
    case BallDockEdge::kRight:
      host_x = work.right - host_width;
      host_y = work.top + along - host_height / 2;
      break;
    case BallDockEdge::kTop:
      host_y = work.top;
      host_x = work.left + along - host_width / 2;
      break;
    case BallDockEdge::kBottom:
      host_y = work.bottom - host_height;
      host_x = work.left + along - host_width / 2;
      break;
  }
  host_x = std::clamp(host_x, static_cast<int>(work.left),
                      static_cast<int>(work.right - host_width));
  host_y = std::clamp(host_y, static_cast<int>(work.top),
                      static_cast<int>(work.bottom - host_height));
  SetWindowPos(host_window_, HWND_TOPMOST, host_x, host_y, 0, 0,
               SWP_NOSIZE | SWP_NOACTIVATE);
  positioned_once_ = true;

  // The ball rides the clamped host so it stays fully inside the work area
  // even when the host is pinned against a screen corner.
  GetWindowRect(host_window_, &host);
  const int host_along = vertical_edge ? host.top : host.left;
  const int work_start = vertical_edge ? work.top : work.left;
  const int in_host_along =
      std::clamp(work_start + along - host_along, min_along, max_along);
  offset_ = (host_along + in_host_along - work_start) / scale;

  int ball_x = host.left;
  int ball_y = host.top;
  switch (edge_) {
    case BallDockEdge::kLeft:
      ball_x = host.left + margin;
      ball_y = host.top + in_host_along - size / 2;
      break;
    case BallDockEdge::kRight:
      ball_x = host.right - margin - size;
      ball_y = host.top + in_host_along - size / 2;
      break;
    case BallDockEdge::kTop:
      ball_y = host.top + margin;
      ball_x = host.left + in_host_along - size / 2;
      break;
    case BallDockEdge::kBottom:
      ball_y = host.bottom - margin - size;
      ball_x = host.left + in_host_along - size / 2;
      break;
  }

  SetWindowPos(window_, HWND_TOPMOST, ball_x, ball_y, size, size,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  Render();
}

LRESULT CALLBACK NativeBallWindow::WndProc(HWND window,
                                           UINT message,
                                           WPARAM wparam,
                                           LPARAM lparam) noexcept {
  NativeBallWindow* ball = reinterpret_cast<NativeBallWindow*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    ball = static_cast<NativeBallWindow*>(create->lpCreateParams);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(ball));
  }
  if (ball) {
    return ball->MessageHandler(window, message, wparam, lparam);
  }
  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT NativeBallWindow::MessageHandler(HWND window,
                                         UINT message,
                                         WPARAM wparam,
                                         LPARAM lparam) noexcept {
  switch (message) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;

    case WM_MOUSEMOVE: {
      if (!tracking_mouse_) {
        TRACKMOUSEEVENT tracking{};
        tracking.cbSize = sizeof(TRACKMOUSEEVENT);
        tracking.dwFlags = TME_LEAVE;
        tracking.hwndTrack = window;
        TrackMouseEvent(&tracking);
        tracking_mouse_ = true;
        SetHovered(true);
        Notify("enter");
      }

      if (pointer_down_) {
        POINT cursor{};
        GetCursorPos(&cursor);
        const int delta_x = cursor.x - drag_start_cursor_.x;
        const int delta_y = cursor.y - drag_start_cursor_.y;
        if (std::abs(delta_x) > 3 || std::abs(delta_y) > 3) {
          dragging_ = true;
        }
        if (dragging_ && !drag_start_notified_) {
          drag_start_notified_ = true;
          Notify("dragStart");
        }
        if (dragging_) {
          const int width = drag_start_window_.right - drag_start_window_.left;
          const int height =
              drag_start_window_.bottom - drag_start_window_.top;
          SetWindowPos(window_, HWND_TOPMOST,
                       drag_start_window_.left + delta_x,
                       drag_start_window_.top + delta_y, width, height,
                       SWP_NOACTIVATE);
        }
      }
      return 0;
    }

    case WM_MOUSELEAVE:
      tracking_mouse_ = false;
      SetHovered(false);
      Notify("exit");
      return 0;

    case WM_LBUTTONDOWN:
      pointer_down_ = true;
      dragging_ = false;
      drag_start_notified_ = false;
      GetCursorPos(&drag_start_cursor_);
      GetWindowRect(window_, &drag_start_window_);
      SetCapture(window);
      return 0;

    case WM_LBUTTONUP:
      if (GetCapture() == window) {
        ReleaseCapture();
      }
      pointer_down_ = false;
      if (dragging_) {
        const BallDockEdge edge = SnapToNearestEdge();
        char buffer[64];
        snprintf(buffer, sizeof(buffer), "moved:%s:%.1f",
                 BallDockEdgeName(edge), offset_);
        Notify(buffer);
      } else {
        Notify("tap");
      }
      dragging_ = false;
      return 0;

    case WM_RBUTTONUP:
      Notify("secondaryTap");
      return 0;

    case WM_ERASEBKGND:
      return 1;

    case WM_TIMER:
      if (wparam == 1 && window_) {
        SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      }
      return 0;

    case WM_CAPTURECHANGED:
      // The capture can be lost without WM_LBUTTONUP (for example when the
      // window is deactivated mid-drag). Treat it as a release so the ball
      // snaps and the host follows, keeping ball and host aligned.
      if (pointer_down_) {
        pointer_down_ = false;
        if (dragging_) {
          const BallDockEdge edge = SnapToNearestEdge();
          char buffer[64];
          snprintf(buffer, sizeof(buffer), "moved:%s:%.1f",
                   BallDockEdgeName(edge), offset_);
          Notify(buffer);
        }
        dragging_ = false;
      }
      return 0;

    case WM_USER + 101:
      // Debug hook: force the ball into a deterministic corner of the host
      // so out-of-process tooling (PowerShell regression tests) can verify
      // the orbit's corner-aware geometry without simulating a real drag.
      // The chosen offset (44) is exactly the ball center distance from the
      // nearest host edge when the ball is parked in a corner.
      SetDock(BallDockEdge::kRight, 44.0);
      PositionForHost();
      Show();
      return 0;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

void NativeBallWindow::SetHovered(bool hovered) {
  if (hovered_ == hovered) {
    return;
  }
  hovered_ = hovered;
  Render();
}

BallDockEdge NativeBallWindow::SnapToNearestEdge() {
  RECT ball{};
  GetWindowRect(window_, &ball);
  HMONITOR monitor = MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(monitor, &monitor_info);
  const RECT work = monitor_info.rcWork;
  const int size = ball.right - ball.left;
  const int center_x = ball.left + size / 2;
  const int center_y = ball.top + size / 2;
  const int to_left = center_x - work.left;
  const int to_right = work.right - center_x;
  const int to_top = center_y - work.top;
  const int to_bottom = work.bottom - center_y;
  const BallDockEdge previous_edge = edge_;
  if (to_left <= to_right && to_left <= to_top && to_left <= to_bottom) {
    edge_ = BallDockEdge::kLeft;
  } else if (to_right <= to_top && to_right <= to_bottom) {
    edge_ = BallDockEdge::kRight;
  } else if (to_top <= to_bottom) {
    edge_ = BallDockEdge::kTop;
  } else {
    edge_ = BallDockEdge::kBottom;
  }
  const double scale = (dpi_ > 0 ? dpi_ : 96.0) / 96.0;
  offset_ =
      (edge_ == BallDockEdge::kLeft || edge_ == BallDockEdge::kRight)
          ? (center_y - work.top) / scale
          : (center_x - work.left) / scale;
  PositionForHost();
  if (dock_changed_callback_ && previous_edge != edge_) {
    dock_changed_callback_(edge_);
  }
  return edge_;
}

void NativeBallWindow::SetDock(BallDockEdge edge, double offset) {
  const BallDockEdge previous_edge = edge_;
  edge_ = edge;
  offset_ = offset;
  if (dock_changed_callback_ && previous_edge != edge_) {
    dock_changed_callback_(edge_);
  }
}

void NativeBallWindow::SetDockChangedCallback(DockChangedCallback callback) {
  dock_changed_callback_ = std::move(callback);
}

void NativeBallWindow::SetExpanded(double progress) {
  const double clamped = std::clamp(progress, 0.0, 1.0);
  if (std::abs(clamped - expand_progress_) < 1e-3) {
    return;
  }
  expand_progress_ = clamped;
  Render();
}

NativeBallWindow::Geometry NativeBallWindow::GetGeometry() const {
  Geometry geometry;
  geometry.edge = edge_;
  geometry.offset = offset_;
  RECT ball{};
  RECT host{};
  if (window_ && GetWindowRect(window_, &ball) && host_window_ &&
      GetWindowRect(host_window_, &host)) {
    const double scale = (dpi_ > 0 ? dpi_ : 96.0) / 96.0;
    const int size = ball.right - ball.left;
    geometry.center_x = (ball.left + size / 2.0 - host.left) / scale;
    geometry.center_y = (ball.top + size / 2.0 - host.top) / scale;
  }
  return geometry;
}

void NativeBallWindow::Notify(const std::string& event) {
  if (callback_) {
    callback_(event);
  }
}

void NativeBallWindow::Render() {
  if (!window_) {
    return;
  }

  RECT bounds{};
  GetWindowRect(window_, &bounds);
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  if (width <= 0 || height <= 0) {
    return;
  }

  HDC screen_dc = GetDC(nullptr);
  HDC memory_dc = CreateCompatibleDC(screen_dc);
  // The DIB header (BITMAPINFOHEADER) is followed by up to four DWORD
  // colour masks when biCompression == BI_ALPHABITFIELDS. Packing the
  // header and the masks in a contiguous buffer avoids the
  // out-of-bounds bmiColors[N] access that MSVC's strict mode rejects
  // and gives the DIB section a real per-pixel alpha channel. Without
  // this, the cleared "transparent" 0x00000000 pixels came back as
  // opaque black rectangles behind the ball.
  struct {
    BITMAPINFOHEADER hdr;
    DWORD masks[4];
  } dib{};
  dib.hdr.biSize = sizeof(BITMAPINFOHEADER);
  dib.hdr.biWidth = width;
  dib.hdr.biHeight = -height;
  dib.hdr.biPlanes = 1;
  dib.hdr.biBitCount = 32;
  dib.hdr.biCompression = BI_BITFIELDS;
  dib.masks[0] = 0x00FF0000;  // red
  dib.masks[1] = 0x0000FF00;  // green
  dib.masks[2] = 0x000000FF;  // blue
  dib.masks[3] = 0xFF000000;  // alpha

  void* raw_pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(screen_dc, reinterpret_cast<BITMAPINFO*>(&dib),
                                    DIB_RGB_COLORS, &raw_pixels, nullptr, 0);
  // CreateDIBSection fails under GDI handle exhaustion or an extreme DPI
  // size. Skip this frame instead of writing through a null pixel pointer;
  // the next render tick retries.
  if (!memory_dc || !bitmap || !raw_pixels) {
    if (bitmap) DeleteObject(bitmap);
    if (memory_dc) DeleteDC(memory_dc);
    ReleaseDC(nullptr, screen_dc);
    return;
  }
  HGDIOBJ old_bitmap = SelectObject(memory_dc, bitmap);
  auto* pixels = static_cast<uint32_t*>(raw_pixels);
  std::fill(pixels, pixels + width * height, 0);

  const double scale = width / kLogicalBallSize;
  if (const uint32_t* main_ball = MainBallPixels()) {
    for (int py = 0; py < height; ++py) {
      const int source_y = std::min(71, py * 72 / height);
      for (int px = 0; px < width; ++px) {
        const int source_x = std::min(71, px * 72 / width);
        pixels[py * width + px] = main_ball[source_y * 72 + source_x];
      }
    }
  } else {
    // DPI-scaled fallback: preserve a circular ball if the native window is
    // not at its normal 72px size or the packaged resource is unavailable.
    const double antialias_width = 1.0 / scale;
    for (int py = 0; py < height; ++py) {
      for (int px = 0; px < width; ++px) {
        const double x = (px + 0.5) / scale;
        const double y = (py + 0.5) / scale;
        uint32_t* pixel = &pixels[py * width + px];
        BlendPixel(pixel, 255, 245, 233,
                   CircleCoverage(x, y, 36, 36, 35, antialias_width));
        BlendPixel(pixel, 42, 39, 34,
                   CircleCoverage(x, y, 36, 36, 31.5, antialias_width));
      }
    }
  }

  POINT destination{bounds.left, bounds.top};
  SIZE size{width, height};
  POINT source{0, 0};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  // When the constellation is open, the ball becomes fully opaque. Otherwise,
  // fall back to the existing idle / hover blend.
  const bool active = expand_progress_ > 0.5 || hovered_;
  blend.SourceConstantAlpha =
      active ? kHoverWindowAlpha : kIdleWindowAlpha;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(window_, screen_dc, &destination, &size, memory_dc,
                      &source, 0, &blend, ULW_ALPHA);

  SelectObject(memory_dc, old_bitmap);
  DeleteObject(bitmap);
  DeleteDC(memory_dc);
  ReleaseDC(nullptr, screen_dc);
}
