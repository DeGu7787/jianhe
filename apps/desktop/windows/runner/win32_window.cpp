#include "win32_window.h"

#include <algorithm>
#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

// JIANHE_USE_NATIVE_BALL is injected by CMake target_compile_definitions so
// the same value is visible to flutter_window.cpp (which creates the native
// ball/orbit windows) and main.cpp (which picks the initial host size). 0 =
// Flutter-render path, the host must stay opaque so the in-Flutter ball and
// arc menu can be seen. 1 = native GDI+ path, the host is fully transparent
// so the native orbit/ball on top shows.
#if !defined(JIANHE_USE_NATIVE_BALL)
#define JIANHE_USE_NATIVE_BALL 0
#endif

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
// The window background used during a resize, before the Flutter engine draws
// the next frame. It matches the Dart transparentKey so the resize gap never
// flashes a jarring black rectangle.
constexpr COLORREF kTransparentColorKey = RGB(20, 19, 17);
/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

constexpr double kLogicalBallSize = 72.0;
constexpr double kLogicalBallMargin = 8.0;

// Returns the dock edge the rectangle center is closest to within the work
// area. Used after a drag so the window can snap to any of the four edges.
BallDockEdge NearestDockEdge(const RECT& rect, const RECT& work) {
  const int cx = rect.left + (rect.right - rect.left) / 2;
  const int cy = rect.top + (rect.bottom - rect.top) / 2;
  const int to_left = cx - work.left;
  const int to_right = work.right - cx;
  const int to_top = cy - work.top;
  const int to_bottom = work.bottom - cy;
  if (to_left <= to_right && to_left <= to_top && to_left <= to_bottom) {
    return BallDockEdge::kLeft;
  }
  if (to_right <= to_top && to_right <= to_bottom) {
    return BallDockEdge::kRight;
  }
  return to_top <= to_bottom ? BallDockEdge::kTop : BallDockEdge::kBottom;
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

const char* BallDockEdgeName(BallDockEdge edge) {
  switch (edge) {
    case BallDockEdge::kLeft:
      return "left";
    case BallDockEdge::kRight:
      return "right";
    case BallDockEdge::kTop:
      return "top";
    case BallDockEdge::kBottom:
      return "bottom";
  }
  return "right";
}

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
  HBRUSH background_brush_ = nullptr;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hbrBackground = CreateSolidBrush(kTransparentColorKey);
    background_brush_ = window_class.hbrBackground;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  if (background_brush_) {
    DeleteObject(background_brush_);
    background_brush_ = nullptr;
  }
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindowEx(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED,
      window_class, title.c_str(), WS_POPUP,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  // Make the host fully transparent (alpha=0) from the start. The D3D child
  // is hidden in non-panel states and we want the native orbit/ball to
  // composite directly with the desktop. The DWM composition path used to
  // be enabled here, but ANGLE on Windows ignores the D3D swap chain's
  // per-pixel alpha, so the DWM path did not actually achieve transparency
  // and the user saw the dark RGB(20,19,17) rectangle.
  // With the native ball/orbit disabled (JIANHE_USE_NATIVE_BALL=0) the
  // host has to stay visible so the in-Flutter ball and arc menu can
  // actually be seen; otherwise the host would be a fully transparent
  // 520x640 hole and the user would see no UI at all.
#if JIANHE_USE_NATIVE_BALL
  SetLayeredWindowAttributes(window, 0, 0, LWA_ALPHA);
#else
  SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA);
#endif  // JIANHE_USE_NATIVE_BALL

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCHITTEST:
      // The Flutter view renders via D3D into a child window whose GDI
      // backing store is empty (pure color-key black), so DefWindowProc's
      // hit test reports HTNOWHERE and every click falls through. Claim the
      // whole client area here so clicks reach the Flutter engine, which does
      // its own render-tree hit testing for real panel content. When that
      // content is hidden, the native ball/menu owns the interaction and this
      // fully transparent host must not block desktop clicks.
      return panel_visible_ ? HTCLIENT : HTTRANSPARENT;

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Decouple the D3D child from the host. The host resizes on every
        // setSize, but ANGLE/DXGI rebuilds the swap chain on every resize
        // and a fresh swap chain starts cleared to opaque black, which is
        // the source of the visible black flash when entering a panel stage.
        // The host's SetWindowRgn clips the visible area to the panel rect
        // anyway, so the D3D child stays as large as the monitor work area for
        // the whole session. The panel cannot be resized beyond that work
        // area (WM_GETMINMAXINFO below), which means interactive resizing never
        // has to rebuild ANGLE's swap chain.
        //
        // Keep the child grow-only across monitor changes. Shrinking the panel
        // leaves the child oversized; the parent host clips the overflow.
        const UINT dpi = GetDpiForWindow(window_handle_);
        const double scale = dpi / 96.0;
        // Composer is the largest BallWindowStage (520x640 logical); pad
        // by 8 logical px on each side so the panel margin never has to
        // recompute when stage sizes change.
        const int kMaxLogicalW = 520 + 16;
        const int kMaxLogicalH = 640 + 16;
        int target_w = static_cast<int>(std::round(kMaxLogicalW * scale));
        int target_h = static_cast<int>(std::round(kMaxLogicalH * scale));
        HMONITOR monitor =
            MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST);
        MONITORINFO monitor_info{};
        monitor_info.cbSize = sizeof(MONITORINFO);
        if (GetMonitorInfo(monitor, &monitor_info)) {
          const RECT work = monitor_info.rcWork;
          target_w = std::max(
              target_w, static_cast<int>(work.right - work.left));
          target_h = std::max(
              target_h, static_cast<int>(work.bottom - work.top));
        }
        RECT child_rect{};
        if (GetWindowRect(child_content_, &child_rect)) {
          target_w = std::max(
              target_w, static_cast<int>(child_rect.right - child_rect.left));
          target_h = std::max(
              target_h, static_cast<int>(child_rect.bottom - child_rect.top));
        }
        target_w = std::max(
            target_w, static_cast<int>(rect.right - rect.left));
        target_h = std::max(
            target_h, static_cast<int>(rect.bottom - rect.top));
        RECT current_child{};
        GetClientRect(child_content_, &current_child);
        if (current_child.right - current_child.left != target_w ||
            current_child.bottom - current_child.top != target_h) {
          MoveWindow(child_content_, rect.left, rect.top, target_w, target_h,
                     TRUE);
        }
      }
      return 0;
    }

    case WM_GETMINMAXINFO: {
      if (panel_visible_) {
        auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
        const UINT dpi = GetDpiForWindow(window_handle_);
        const double scale = dpi / 96.0;
        // Smallest usable panel: the ball strip (72 logical px) plus the 8 px
        // margins plus a workable content area. Every panel view lays out at
        // this size without breaking (headers stay, lists scroll).
        info->ptMinTrackSize.x = static_cast<LONG>(std::round(320.0 * scale));
        info->ptMinTrackSize.y = static_cast<LONG>(std::round(400.0 * scale));
        // Cap the panel at the work area so ResizeDocked's position clamps
        // (work.right - width) can never invert. Only user-initiated resize
        // loops consult these values; programmatic setSize stage changes are
        // unaffected.
        HMONITOR monitor =
            MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST);
        MONITORINFO monitor_info{};
        monitor_info.cbSize = sizeof(MONITORINFO);
        if (GetMonitorInfo(monitor, &monitor_info)) {
          const RECT work = monitor_info.rcWork;
          info->ptMaxTrackSize.x = work.right - work.left;
          info->ptMaxTrackSize.y = work.bottom - work.top;
        }
        return 0;
      }
      break;  // menu/collapsed: fall through to DefWindowProc (no resize UI)
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  // Do NOT add WS_EX_LAYERED to the child. ANGLE on Windows creates the
  // swap chain with DXGI_ALPHA_MODE_IGNORE, so a per-pixel-alpha D3D child
  // would be composited as fully opaque by DWM. The child stays alive behind
  // the host; outside panel stages the host alpha is 0 and the native orbit
  // window owns the visible menu.
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

void Win32Window::SetPanelVisible(bool visible, BYTE initial_opacity) {
  if (!window_handle_) {
    return;
  }

  panel_visible_ = visible;

  // Panel stages are fully opaque (paper background, black text), so the
  // color key must be disabled there; otherwise any pure-black text/icon
  // would be punched through. Collapsed and menu stages keep the color key
  // so the unpainted background stays invisible.
  if (visible) {
    // Panel stages: in native-ball mode the D3D child is the source of every
    // visible panel pixel, but the D3D child sits inside the host as a child
    // window. When the host is a WS_EX_LAYERED window with alpha=0 the
    // composited child framebuffer is multiplied by that alpha too, which
    // makes the panel disappear. The fix is to keep the host fully opaque
    // (alpha=255) here and instead clip the host's visible area to the panel
    // region via SetWindowRgn - that lets the D3D child paint normally and
    // still leaves the margins around the panel transparent. The caller must
    // install the matching host/D3D region before entering this visible state.
#if JIANHE_USE_NATIVE_BALL
    SetPanelOpacity(initial_opacity);
#else
    SetPanelOpacity(initial_opacity);
#endif  // JIANHE_USE_NATIVE_BALL
  } else {
    // Menu/collapsed stages: the D3D child stays warm behind an alpha=0 host.
    // The native orbit/ball (HWND_TOPMOST) remains visible to the user.
    // Hiding the host entirely (SW_HIDE) was found to
    // confuse DWM's z-order at the same screen position - the orbit's
    // pixels would not be composited to the screen even with HWND_TOPMOST.
    // Keeping the host "visible" with alpha=0 lets the orbit sit on top of
    // an invisible host. In Flutter-render mode the native windows are not
    // created, so we have to keep the host itself opaque for the in-Flutter
    // ball and menu to show.
#if JIANHE_USE_NATIVE_BALL
    SetPanelOpacity(0);
#else
    SetPanelOpacity(255);
#endif  // JIANHE_USE_NATIVE_BALL
  }
  // Region handling is owned by UpdatePanelRegion: it sets a panel-shaped
  // region on both the host and the D3D child in panel stages and clears it
  // everywhere else. Do NOT clobber the host region here - that would race
  // with the region UpdatePanelRegion just installed.
  SetWindowPos(window_handle_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  RedrawWindow(window_handle_, nullptr, nullptr,
               RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
}

void Win32Window::SetPanelOpacity(BYTE opacity) {
  if (window_handle_) {
    SetLayeredWindowAttributes(window_handle_, 0, opacity, LWA_ALPHA);
  }
}

BallDockEdge Win32Window::ResizeDocked(unsigned int width, unsigned int height,
                                       BallDockEdge edge, double offset) {
  if (!window_handle_) {
    return edge;
  }

  RECT current{};
  GetWindowRect(window_handle_, &current);
  HMONITOR monitor = MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(monitor, &monitor_info);
  const RECT work = monitor_info.rcWork;

  const UINT dpi = GetDpiForWindow(window_handle_);
  const double scale_factor = dpi / 96.0;
  // Clamp the requested size to the work area so the position clamps below
  // (work.right - target_width etc.) can never invert. User-resized panels
  // and oversized saved sizes are capped to what fits on the monitor.
  const int max_width = std::max(1, static_cast<int>(work.right - work.left));
  const int max_height = std::max(1, static_cast<int>(work.bottom - work.top));
  const int target_width =
      std::clamp(Scale(width, scale_factor), 1, max_width);
  const int target_height =
      std::clamp(Scale(height, scale_factor), 1, max_height);
  const int margin = Scale(static_cast<int>(kLogicalBallMargin), scale_factor);
  const int ball_size = Scale(static_cast<int>(kLogicalBallSize), scale_factor);
  const int min_along = margin + ball_size / 2;
  const bool vertical_edge =
      edge == BallDockEdge::kLeft || edge == BallDockEdge::kRight;
  const int extent = vertical_edge ? (work.bottom - work.top)
                                   : (work.right - work.left);
  const int max_along = std::max(min_along, extent - min_along);
  const int along = std::clamp(
      static_cast<int>(std::round(offset * scale_factor)), min_along, max_along);

  int x = current.left;
  int y = current.top;
  switch (edge) {
    case BallDockEdge::kLeft:
      x = work.left;
      y = work.top + along - target_height / 2;
      break;
    case BallDockEdge::kRight:
      x = work.right - target_width;
      y = work.top + along - target_height / 2;
      break;
    case BallDockEdge::kTop:
      y = work.top;
      x = work.left + along - target_width / 2;
      break;
    case BallDockEdge::kBottom:
      y = work.bottom - target_height;
      x = work.left + along - target_width / 2;
      break;
  }
  x = std::clamp(x, static_cast<int>(work.left),
                 static_cast<int>(work.right - target_width));
  y = std::clamp(y, static_cast<int>(work.top),
                 static_cast<int>(work.bottom - target_height));

  SetWindowPos(window_handle_, HWND_TOPMOST, x, y, target_width, target_height,
               SWP_NOACTIVATE);
  return edge;
}

void Win32Window::DragAndSnap(BallDockEdge* edge_out, double* offset_out) {
  if (!window_handle_) {
    if (edge_out) {
      *edge_out = BallDockEdge::kRight;
    }
    if (offset_out) {
      *offset_out = 0.0;
    }
    return;
  }

  ReleaseCapture();
  SendMessage(window_handle_, WM_NCLBUTTONDOWN, HTCAPTION, 0);

  RECT current{};
  GetWindowRect(window_handle_, &current);
  HMONITOR monitor = MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(monitor, &monitor_info);
  const RECT work = monitor_info.rcWork;
  const UINT dpi = GetDpiForWindow(window_handle_);
  const double scale_factor = dpi / 96.0;
  const int width = current.right - current.left;
  const int height = current.bottom - current.top;

  const BallDockEdge edge = NearestDockEdge(current, work);
  const int cx = current.left + width / 2;
  const int cy = current.top + height / 2;
  const double offset =
      (edge == BallDockEdge::kLeft || edge == BallDockEdge::kRight)
          ? (cy - work.top) / scale_factor
          : (cx - work.left) / scale_factor;

  int x = current.left;
  int y = current.top;
  switch (edge) {
    case BallDockEdge::kLeft:
      x = work.left;
      y = std::clamp(static_cast<int>(current.top), static_cast<int>(work.top),
                     static_cast<int>(work.bottom - height));
      break;
    case BallDockEdge::kRight:
      x = work.right - width;
      y = std::clamp(static_cast<int>(current.top), static_cast<int>(work.top),
                     static_cast<int>(work.bottom - height));
      break;
    case BallDockEdge::kTop:
      y = work.top;
      x = std::clamp(static_cast<int>(current.left),
                     static_cast<int>(work.left),
                     static_cast<int>(work.right - width));
      break;
    case BallDockEdge::kBottom:
      y = work.bottom - height;
      x = std::clamp(static_cast<int>(current.left),
                     static_cast<int>(work.left),
                     static_cast<int>(work.right - width));
      break;
  }

  SetWindowPos(window_handle_, HWND_TOPMOST, x, y, width, height,
               SWP_NOACTIVATE);
  if (edge_out) {
    *edge_out = edge;
  }
  if (offset_out) {
    *offset_out = offset;
  }
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
