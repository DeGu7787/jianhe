#include "native_orbit_window.h"

#include <gdiplus.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <utility>

#include "resource.h"

// MSVC's standard library does not expose POSIX math constants (M_PI etc.)
// even with _USE_MATH_DEFINES, so we keep our own local constant for the
// arc-layout code. Anywhere we'd otherwise write M_PI in the orbit window
// reads from here as kTwoPi * 0.5, and 2 * M_PI reads as kTwoPi.
static constexpr double kTwoPi = 6.28318530717958647692;

namespace {

constexpr wchar_t kOrbitWindowClassName[] = L"JIANHE_NATIVE_ORBIT_WINDOW";
constexpr double kLogicalOrbitWidth = 390.0;
constexpr double kLogicalOrbitHeight = 360.0;

constexpr double kOrbitRadius = 130.0;  // sub-ball center to main-ball center
constexpr double kSubBallRadius = 28.0;  // sub-ball visual radius
constexpr double kSubBallDiameter = kSubBallRadius * 2.0;  // 56 px
constexpr double kMaxRadiusFactor = 1.45;  // see ComputeArcLayout search range
constexpr double kLabelHeight = 22.0;     // height reserved for the label
constexpr float kLabelHorizontalPadding = 8.0f;
constexpr float kLabelCornerRadius = 6.0f;
constexpr double kScreenMargin = 16.0;    // safe area from any host edge
constexpr double kArcSpanRad = 5.0 * 3.14159265358979323846 / 6.0;  // 150 deg
constexpr double kStaggerMs = 45.0;
constexpr double kExpandDurationMs = 280.0;
constexpr double kCollapseDurationMs = 180.0;

// Corner-aware geometry. When the main ball sits near a host corner the
// 150 deg single-arc would extend past the host edge, so the preferred
// centre direction is rotated away from the cardinal (edge-perpendicular)
// toward the host's geometric centre. The actual arc is then laid out by
// ComputeArcLayout, which intersects the four screen-edge constraints to
// keep every sub-ball inside the host and uses the chord-length rule
// (2R sin(theta/2) >= sub-ball diameter) to keep neighbours from
// overlapping. See IsCornerMode / SubBallTargetPosition /
// ComputeArcLayout.
constexpr double kCornerThreshold =
    130.0;  // logical px from any host corner triggers corner mode

// Main ball geometry constants mirror NativeBallWindow so the constellation
// anchors to the right pixel even when the live geometry is unavailable.
constexpr double kBallMargin = 8.0;
constexpr double kBallRadius = 36.0;
constexpr double kBallCenterOffset = kBallMargin + kBallRadius;  // 44.0


constexpr UINT kAnimTimerId = 2;
constexpr INT kActionImageCacheSize = 128;

constexpr int kActionImageResourceIds[] = {
    IDR_ORBIT_ACTION_6, IDR_ORBIT_ACTION_5, IDR_ORBIT_ACTION_4,
    IDR_ORBIT_ACTION_3, IDR_ORBIT_ACTION_2, IDR_ORBIT_ACTION_1,
};

enum class OrbitIcon {
  kSparkles,
  kChat,
  kDocument,
  kTextDocument,
  kPlus,
  kMore,
};

struct OrbitAction {
  const wchar_t* label;
  // Shown when the interface language is English. Kept short: the hover chip
  // is a fixed kLabelWidth (70 px) wide.
  const wchar_t* english_label;
  const char* event;
  BYTE red;
  BYTE green;
  BYTE blue;
  OrbitIcon icon;
};

constexpr OrbitAction kActions[] = {
    {L"\u5FEB\u901F\u62FC\u88C5", L"Compose", "compose", 234, 106, 57,
     OrbitIcon::kSparkles},
    {L"Prompt", L"Prompt", "prompts", 217, 140, 49, OrbitIcon::kChat},
    {L"Skills", L"Skills", "skills", 76, 114, 184,
     OrbitIcon::kDocument},
    {L"\u5E38\u7528\u6587\u672C", L"Snippets", "snippets", 52, 120, 92,
     OrbitIcon::kTextDocument},
    {L"\u65B0\u5EFA", L"New", "create", 154, 92, 143, OrbitIcon::kPlus},
    {L"\u66F4\u591A", L"More", "more", 93, 89, 82, OrbitIcon::kMore},
};

constexpr size_t kActionCount = sizeof(kActions) / sizeof(kActions[0]);
static_assert(kActionCount ==
              sizeof(kActionImageResourceIds) /
                  sizeof(kActionImageResourceIds[0]));

Gdiplus::Bitmap* LoadPngResource(int resource_id) {
  HRSRC resource = FindResource(GetModuleHandle(nullptr),
                                MAKEINTRESOURCE(resource_id), RT_RCDATA);
  if (!resource) {
    return nullptr;
  }
  const DWORD size = SizeofResource(GetModuleHandle(nullptr), resource);
  HGLOBAL loaded = LoadResource(GetModuleHandle(nullptr), resource);
  const void* bytes = loaded ? LockResource(loaded) : nullptr;
  if (!bytes || size == 0) {
    return nullptr;
  }

  HGLOBAL copy = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!copy) {
    return nullptr;
  }
  void* destination = GlobalLock(copy);
  if (!destination) {
    GlobalFree(copy);
    return nullptr;
  }
  memcpy(destination, bytes, size);
  GlobalUnlock(copy);

  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(copy, TRUE, &stream) != S_OK) {
    GlobalFree(copy);
    return nullptr;
  }
  Gdiplus::Bitmap* decoded = Gdiplus::Bitmap::FromStream(stream);
  Gdiplus::Bitmap* bitmap = nullptr;
  if (decoded && decoded->GetLastStatus() == Gdiplus::Ok) {
    bitmap = new Gdiplus::Bitmap(kActionImageCacheSize,
                                 kActionImageCacheSize,
                                 PixelFormat32bppPARGB);
    if (bitmap->GetLastStatus() == Gdiplus::Ok) {
      Gdiplus::Graphics cache_graphics(bitmap);
      cache_graphics.SetCompositingMode(Gdiplus::CompositingModeSourceCopy);
      cache_graphics.SetCompositingQuality(
          Gdiplus::CompositingQualityHighQuality);
      cache_graphics.SetInterpolationMode(
          Gdiplus::InterpolationModeHighQualityBicubic);
      cache_graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
      const UINT source_size =
          std::min(decoded->GetWidth(), decoded->GetHeight());
      const UINT source_x = (decoded->GetWidth() - source_size) / 2;
      const UINT source_y = (decoded->GetHeight() - source_size) / 2;
      cache_graphics.DrawImage(
          decoded,
          Gdiplus::Rect(0, 0, kActionImageCacheSize, kActionImageCacheSize),
          source_x, source_y, source_size, source_size, Gdiplus::UnitPixel);
      cache_graphics.Flush(Gdiplus::FlushIntentionSync);
    }
  }
  delete decoded;
  stream->Release();
  if (!bitmap || bitmap->GetLastStatus() != Gdiplus::Ok) {
    delete bitmap;
    return nullptr;
  }
  return bitmap;
}

Gdiplus::Bitmap* ActionImage(size_t index) {
  static Gdiplus::Bitmap* images[kActionCount] = {};
  static bool loaded = false;
  if (!loaded) {
    loaded = true;
    for (size_t i = 0; i < kActionCount; ++i) {
      images[i] = LoadPngResource(kActionImageResourceIds[i]);
    }
  }
  return index < kActionCount ? images[index] : nullptr;
}

struct SubBallRenderState {
  double current_x;
  double current_y;
  double individual_progress;  // 0..1, with stagger and easing
};

double CenterAngleForEdge(BallDockEdge edge) {
  switch (edge) {
    case BallDockEdge::kLeft:
      return 0.0;  // arc opens to the right (toward screen interior)
    case BallDockEdge::kRight:
      return 3.14159265358979323846;  // arc opens to the left
    case BallDockEdge::kTop:
      return 3.14159265358979323846 / 2.0;  // arc opens down
    case BallDockEdge::kBottom:
      return 3.0 * 3.14159265358979323846 / 2.0;  // arc opens up
  }
  return 0.0;
}

// Returns true when the main ball sits within [kCornerThreshold] logical
// pixels of any host corner. The single 150 deg arc would extend past the
// host edge in that case, so the preferred centre direction shifts from
// the cardinal (ball-to-host-interior) to the host geometric centre.
// When [host_w] or [host_h] is non-positive the function is conservative
// and returns false (i.e. falls back to the normal arc) so the layout
// never misbehaves before the host is positioned.
bool IsCornerMode(double main_x,
                  double main_y,
                  double host_w,
                  double host_h) {
  if (host_w <= 0.0 || host_h <= 0.0) {
    return false;
  }
  const double d_tl = std::hypot(main_x, main_y);
  const double d_tr = std::hypot(host_w - main_x, main_y);
  const double d_bl = std::hypot(main_x, host_h - main_y);
  const double d_br = std::hypot(host_w - main_x, host_h - main_y);
  const double min_dist = std::min({d_tl, d_tr, d_bl, d_br});
  return min_dist < kCornerThreshold;
}

// Angle constraint: a single interval [lo, hi] within [0, 2*pi). Empty
// when the constraint cannot be satisfied for any direction.
struct AnglePiece {
  double lo;
  double hi;
};

using AnglePieceList = std::vector<AnglePiece>;

// cos(theta) >= (limit - center) / radius.
// Returns one or two pieces (split at the 0 / 2*pi seam when needed).
AnglePieceList CosineLowerBoundPieces(double center,
                                      double radius,
                                      double limit) {
  const double k = (limit - center) / radius;
  if (k <= -1.0) {
    return AnglePieceList{{0.0, kTwoPi}};
  }
  if (k >= 1.0) {
    return AnglePieceList{};
  }
  const double a = std::acos(k);
  return AnglePieceList{{0.0, a}, {kTwoPi - a, kTwoPi}};
}

// cos(theta) <= (limit - center) / radius.
AnglePieceList CosineUpperBoundPieces(double center,
                                      double radius,
                                      double limit) {
  const double k = (limit - center) / radius;
  if (k >= 1.0) {
    return AnglePieceList{{0.0, kTwoPi}};
  }
  if (k <= -1.0) {
    return AnglePieceList{};
  }
  const double a = std::acos(k);
  return AnglePieceList{{a, kTwoPi - a}};
}

// sin(theta) >= (limit - center) / radius. The solution [a, pi - a]
// always contains 0 and pi; when a is negative the interval wraps
// through 0, so it has to be split into [0, pi - a] and [2pi + a, 2pi].
AnglePieceList SineLowerBoundPieces(double center,
                                    double radius,
                                    double limit) {
  const double k = (limit - center) / radius;
  if (k <= -1.0) {
    return AnglePieceList{{0.0, kTwoPi}};
  }
  if (k >= 1.0) {
    return AnglePieceList{};
  }
  const double a = std::asin(k);
  if (a >= 0.0) {
    return AnglePieceList{{a, kTwoPi * 0.5 - a}};
  }
  return AnglePieceList{{0.0, kTwoPi * 0.5 - a}, {kTwoPi + a, kTwoPi}};
}

// sin(theta) <= (limit - center) / radius. The solution [pi - a, 2pi + a]
// always contains pi and 0; when a is positive the interval wraps
// through 2pi, so it has to be split into [pi - a, 2pi] and [0, a].
AnglePieceList SineUpperBoundPieces(double center,
                                    double radius,
                                    double limit) {
  const double k = (limit - center) / radius;
  if (k >= 1.0) {
    return AnglePieceList{{0.0, kTwoPi}};
  }
  if (k <= -1.0) {
    return AnglePieceList{};
  }
  const double a = std::asin(k);
  if (a <= 0.0) {
    return AnglePieceList{{kTwoPi * 0.5 - a, kTwoPi + a}};
  }
  return AnglePieceList{{kTwoPi * 0.5 - a, kTwoPi}, {0.0, a}};
}

// Intersect the four screen-edge constraints to obtain the set of safe
// directions. Returns an empty list when the ball is too close to the
// host for any sub-ball to fit.
AnglePieceList SafeAnglePieces(double main_x,
                               double main_y,
                               double radius,
                               double left,
                               double right,
                               double top,
                               double bottom) {
  const std::vector<AnglePieceList> bounds = {
      CosineLowerBoundPieces(main_x, radius, left),
      CosineUpperBoundPieces(main_x, radius, right),
      SineLowerBoundPieces(main_y, radius, top),
      SineUpperBoundPieces(main_y, radius, bottom),
  };
  AnglePieceList result{{0.0, kTwoPi}};
  for (const auto& bound : bounds) {
    if (bound.empty()) return AnglePieceList{};
    AnglePieceList next;
    for (const auto& seg : result) {
      for (const auto& piece : bound) {
        const double lo = std::max(seg.lo, piece.lo);
        const double hi = std::min(seg.hi, piece.hi);
        if (lo < hi) next.push_back({lo, hi});
      }
    }
    result = next;
    if (result.empty()) return AnglePieceList{};
  }
  return result;
}

// Largest contiguous safe window (radians) centred on [direction]. If
// the direction itself is unsafe (sits outside every piece, e.g. when
// the main ball is wedged into a corner) the function returns 0 and the
// caller should fall back to the widest piece.
double DirectedWindow(const AnglePieceList& pieces, double direction) {
  double d = std::fmod(direction, kTwoPi);
  if (d < 0.0) d += kTwoPi;
  for (const auto& piece : pieces) {
    if (d < piece.lo || d > piece.hi) continue;
    if ((piece.hi - piece.lo) >= kTwoPi - 1e-9) return kTwoPi;
    double left = d - piece.lo;
    double right = piece.hi - d;
    // Bridge the seam when a piece touches 0 or 2*pi and another piece
    // sits on the opposite side, so the centred window can wrap.
    if (piece.lo == 0.0 && pieces.size() > 1 &&
        pieces.back().hi == kTwoPi) {
      left += pieces.back().hi - pieces.back().lo;
    }
    if (piece.hi == kTwoPi && pieces.size() > 1 &&
        pieces.front().lo == 0.0) {
      right += pieces.front().hi - pieces.front().lo;
    }
    const double window = std::min(left, right) * 2.0;
    if (window > 1e-6) return window;
    break;
  }
  return 0.0;
}

AnglePiece WidestPiece(const AnglePieceList& pieces) {
  AnglePiece widest = pieces.front();
  for (const auto& piece : pieces) {
    if ((piece.hi - piece.lo) > (widest.hi - widest.lo)) {
      widest = piece;
    }
  }
  return widest;
}

void AddRoundedRectangle(Gdiplus::GraphicsPath* path,
                         const Gdiplus::RectF& bounds,
                         float radius) {
  const float diameter =
      std::min(radius * 2.0f, std::min(bounds.Width, bounds.Height));
  path->AddArc(bounds.X, bounds.Y, diameter, diameter, 180, 90);
  path->AddArc(bounds.GetRight() - diameter, bounds.Y, diameter, diameter, 270,
               90);
  path->AddArc(bounds.GetRight() - diameter,
               bounds.GetBottom() - diameter, diameter, diameter, 0, 90);
  path->AddArc(bounds.X, bounds.GetBottom() - diameter, diameter, diameter, 90,
               90);
  path->CloseFigure();
}

void DrawRoundedRectangle(Gdiplus::Graphics* graphics,
                          const Gdiplus::RectF& bounds,
                          float radius,
                          const Gdiplus::Color& fill,
                          const Gdiplus::Color& stroke,
                          float stroke_width) {
  Gdiplus::GraphicsPath path;
  AddRoundedRectangle(&path, bounds, radius);
  Gdiplus::SolidBrush brush(fill);
  graphics->FillPath(&brush, &path);
  if (stroke_width > 0) {
    Gdiplus::Pen pen(stroke, stroke_width);
    pen.SetAlignment(Gdiplus::PenAlignmentInset);
    graphics->DrawPath(&pen, &path);
  }
}

void DrawDiamond(Gdiplus::Graphics* graphics,
                 float center_x,
                 float center_y,
                 float radius,
                 const Gdiplus::Color& color) {
  const Gdiplus::PointF points[] = {
      {center_x, center_y - radius},
      {center_x + radius * 0.58f, center_y},
      {center_x, center_y + radius},
      {center_x - radius * 0.58f, center_y},
  };
  Gdiplus::SolidBrush brush(color);
  graphics->FillPolygon(&brush, points, 4);
}

void DrawIconAlpha(Gdiplus::Graphics* graphics,
                   OrbitIcon icon,
                   float center_x,
                   float center_y,
                   BYTE alpha) {
  const Gdiplus::Color white(alpha, 255, 255, 255);
  Gdiplus::Pen pen(white, 2.4f);
  pen.SetStartCap(Gdiplus::LineCapRound);
  pen.SetEndCap(Gdiplus::LineCapRound);
  pen.SetLineJoin(Gdiplus::LineJoinRound);
  Gdiplus::SolidBrush brush(white);

  switch (icon) {
    case OrbitIcon::kPlus:
      graphics->DrawLine(&pen, center_x - 8, center_y, center_x + 8, center_y);
      graphics->DrawLine(&pen, center_x, center_y - 8, center_x, center_y + 8);
      break;

    case OrbitIcon::kMore:
      graphics->FillEllipse(&brush,
                            Gdiplus::RectF(center_x - 9, center_y - 2, 4, 4));
      graphics->FillEllipse(&brush,
                            Gdiplus::RectF(center_x - 2, center_y - 2, 4, 4));
      graphics->FillEllipse(&brush,
                            Gdiplus::RectF(center_x + 5, center_y - 2, 4, 4));
      break;

    case OrbitIcon::kChat: {
      Gdiplus::GraphicsPath path;
      AddRoundedRectangle(&path,
                          Gdiplus::RectF(center_x - 10, center_y - 7, 20, 14),
                          2.5f);
      graphics->DrawPath(&pen, &path);
      graphics->DrawLine(&pen, center_x - 5, center_y + 7, center_x - 8,
                         center_y + 10);
      break;
    }

    case OrbitIcon::kDocument:
    case OrbitIcon::kTextDocument:
      graphics->DrawRectangle(&pen,
                              Gdiplus::RectF(center_x - 8, center_y - 10, 16, 20));
      graphics->DrawLine(&pen, center_x - 4, center_y - 3, center_x + 4,
                         center_y - 3);
      graphics->DrawLine(&pen, center_x - 4, center_y + 2, center_x + 4,
                         center_y + 2);
      graphics->DrawLine(&pen, center_x - 4, center_y + 7, center_x + 2,
                         center_y + 7);
      break;

    case OrbitIcon::kSparkles:
      DrawDiamond(graphics, center_x - 5, center_y + 2, 7, white);
      DrawDiamond(graphics, center_x + 7, center_y - 7, 4, white);
      DrawDiamond(graphics, center_x + 8, center_y + 8, 3, white);
      break;
  }
}

void DrawSubBall(Gdiplus::Graphics* graphics,
                 double cx,
                 double cy,
                 const OrbitAction& action,
                 size_t action_index,
                 double progress) {
  if (progress <= 0.0) {
    return;
  }
  const float r = static_cast<float>(kSubBallRadius);
  const float fx = static_cast<float>(cx);
  const float fy = static_cast<float>(cy);
  const BYTE alpha = static_cast<BYTE>(std::clamp(255.0 * progress, 0.0, 255.0));

  // Soft outer glow keeps the sub-balls visually related instead of reading
  // as unrelated chips.
  if (progress > 0.2) {
    const float glow_r = r + 5.0f;
    Gdiplus::GraphicsPath glow_path;
    glow_path.AddEllipse(fx - glow_r, fy - glow_r, glow_r * 2, glow_r * 2);
    Gdiplus::PathGradientBrush glow_brush(&glow_path);
    const BYTE glow_a = static_cast<BYTE>(50.0 * progress);
    glow_brush.SetCenterColor(Gdiplus::Color(glow_a, 255, 247, 234));
    const Gdiplus::Color glow_edge(0, 255, 247, 234);
    INT glow_count = 1;
    glow_brush.SetSurroundColors(&glow_edge, &glow_count);
    glow_brush.SetFocusScales(0.6f, 0.6f);
    graphics->FillEllipse(&glow_brush, fx - glow_r, fy - glow_r, glow_r * 2,
                          glow_r * 2);
  }

  if (Gdiplus::Bitmap* image = ActionImage(action_index)) {
    Gdiplus::ImageAttributes attributes;
    Gdiplus::ColorMatrix opacity = {{
        {1.0f, 0.0f, 0.0f, 0.0f, 0.0f},
        {0.0f, 1.0f, 0.0f, 0.0f, 0.0f},
        {0.0f, 0.0f, 1.0f, 0.0f, 0.0f},
        {0.0f, 0.0f, 0.0f, static_cast<float>(progress), 0.0f},
        {0.0f, 0.0f, 0.0f, 0.0f, 1.0f},
    }};
    attributes.SetColorMatrix(&opacity);
    const Gdiplus::Rect destination(static_cast<INT>(fx - r),
                                    static_cast<INT>(fy - r),
                                    static_cast<INT>(r * 2),
                                    static_cast<INT>(r * 2));
    graphics->DrawImage(image, destination, 0, 0, image->GetWidth(),
                        image->GetHeight(), Gdiplus::UnitPixel, &attributes);
    return;
  }

  // Keep the former vector artwork as a safe fallback if a packaged image
  // cannot be decoded on a particular machine.
  Gdiplus::SolidBrush rim_brush(Gdiplus::Color(alpha, 255, 247, 234));
  graphics->FillEllipse(&rim_brush, fx - r, fy - r, r * 2, r * 2);
  const float ir = r * 0.74f;
  Gdiplus::SolidBrush acc_brush(
      Gdiplus::Color(alpha, action.red, action.green, action.blue));
  graphics->FillEllipse(&acc_brush, fx - ir, fy - ir, ir * 2, ir * 2);
  DrawIconAlpha(graphics, action.icon, fx, fy, alpha);
}

Gdiplus::RectF LabelRect(BallDockEdge edge,
                         double sub_ball_x,
                         double sub_ball_y,
                         size_t index) {
  // Labels are placed in the direction away from the main ball so they
  // don't crowd the constellation. For top/bottom docks they sit
  // vertically; for left/right docks they sit horizontally. The 18 px
  // height is the GDI+ glyph ascent+descent; the safe-area reserved
  // for it elsewhere is a more generous 22 px so the text never clips.
  const float r = static_cast<float>(kSubBallRadius);
  constexpr float kLabelWidth = 70.0f;
  constexpr float kLabelGlyphHeight = 18.0f;
  const float fx = static_cast<float>(sub_ball_x);
  const float fy = static_cast<float>(sub_ball_y);
  switch (edge) {
    case BallDockEdge::kLeft:
      return Gdiplus::RectF(fx + r + 6.0f, fy - kLabelGlyphHeight / 2.0f,
                            kLabelWidth, kLabelGlyphHeight);
    case BallDockEdge::kRight:
      return Gdiplus::RectF(fx - r - 6.0f - kLabelWidth,
                            fy - kLabelGlyphHeight / 2.0f, kLabelWidth,
                            kLabelGlyphHeight);
    case BallDockEdge::kTop:
      return Gdiplus::RectF(fx - kLabelWidth / 2.0f, fy + r + 6.0f,
                            kLabelWidth, kLabelGlyphHeight);
    case BallDockEdge::kBottom:
      return Gdiplus::RectF(fx - kLabelWidth / 2.0f,
                            fy - r - 6.0f - kLabelGlyphHeight, kLabelWidth,
                            kLabelGlyphHeight);
  }
  return Gdiplus::RectF(fx, fy, kLabelWidth, kLabelGlyphHeight);
}

Gdiplus::StringFormat* CreateLabelFormat() {
  Gdiplus::StringFormat* format = new Gdiplus::StringFormat();
  format->SetLineAlignment(Gdiplus::StringAlignmentCenter);
  format->SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  format->SetAlignment(Gdiplus::StringAlignmentCenter);
  return format;
}

}  // namespace

NativeOrbitWindow::NativeOrbitWindow() = default;

NativeOrbitWindow::~NativeOrbitWindow() {
  Destroy();
}

bool NativeOrbitWindow::Create(HWND host_window, EventCallback callback) {
  host_window_ = host_window;
  callback_ = std::move(callback);
  dpi_ = GetDpiForWindow(host_window_);

  Gdiplus::GdiplusStartupInput startup_input;
  if (Gdiplus::GdiplusStartup(&gdiplus_token_, &startup_input, nullptr) !=
      Gdiplus::Ok) {
    return false;
  }

  // Decode the small cached action images during window creation. Keeping
  // this work out of the first Render() call prevents the first click from
  // blocking the expand animation and jumping several frames at once.
  ActionImage(0);

  WNDCLASS definition{};
  definition.hCursor = LoadCursor(nullptr, IDC_HAND);
  definition.lpszClassName = kOrbitWindowClassName;
  definition.hInstance = GetModuleHandle(nullptr);
  definition.lpfnWndProc = NativeOrbitWindow::WndProc;
  definition.hbrBackground = nullptr;
  if (!RegisterClass(&definition)) {
    Destroy();
    return false;
  }

  window_ = CreateWindowEx(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE,
      kOrbitWindowClassName, L"Jianhe Native Orbit", WS_POPUP, 0, 0, 1, 1,
      nullptr, nullptr, GetModuleHandle(nullptr), this);
  if (!window_) {
    Destroy();
    return false;
  }

  PositionForHost(BallDockEdge::kRight);
  Hide();
  return true;
}

void NativeOrbitWindow::Destroy() {
  if (anim_timer_id_ != 0 && window_) {
    KillTimer(window_, anim_timer_id_);
    anim_timer_id_ = 0;
  }
  if (window_) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
  if (gdiplus_token_ != 0) {
    Gdiplus::GdiplusShutdown(gdiplus_token_);
    gdiplus_token_ = 0;
  }
  callback_ = nullptr;
  ball_ = nullptr;
}

void NativeOrbitWindow::Show(BallDockEdge edge, double main_x, double main_y) {
  visible_ = true;
  hide_when_collapsed_ = false;
  dock_edge_ = edge;
  seed_main_x_ = main_x;
  seed_main_y_ = main_y;
  PositionForHost(edge);
}

void NativeOrbitWindow::Hide() {
  visible_ = false;
  hide_when_collapsed_ = false;
  tracking_mouse_ = false;
  hovered_action_index_ = -1;
  if (window_) {
    ShowWindow(window_, SW_HIDE);
  }
}

void NativeOrbitWindow::HideAfterCollapse() {
  hide_when_collapsed_ = true;
  if (!expand_animating_ && expand_progress_ <= 1e-3) {
    Hide();
    return;
  }
  if (expand_target_ || !expand_animating_) {
    SetExpanded(false);
  }
}

void NativeOrbitWindow::PositionForHost(BallDockEdge edge) {
  if (!window_ || !host_window_) {
    return;
  }

  dock_edge_ = edge;
  dpi_ = GetDpiForWindow(host_window_);
  RECT host{};
  GetWindowRect(host_window_, &host);
  const int width = host.right - host.left;
  const int height = host.bottom - host.top;
  // Cache the host's logical-pixel size. SubBallTargetPosition uses it to
  // detect when the main ball is sitting in a host corner and needs the
  // compact two-ring layout. Logical pixels (not physical) because that is
  // the coordinate space the sub-ball layout and the labels share.
  const double scale = (dpi_ > 0 ? dpi_ : 96.0) / 96.0;
  host_width_logical_ = static_cast<double>(width) / scale;
  host_height_logical_ = static_cast<double>(height) / scale;
  UINT flags = SWP_NOACTIVATE;
  if (visible_) {
    flags |= SWP_SHOWWINDOW;
  }
  SetWindowPos(window_, HWND_TOPMOST, host.left, host.top, width, height, flags);
  // PositionForHost is called for every host move/resize, even when the
  // orbit is hidden (so it is ready to show at the right spot). Skip the
  // GDI+ render in that case to avoid drawing a menu nobody will see.
  if (visible_) {
    Render();
  }
}

void NativeOrbitWindow::SetEnglishLabels(bool english) {
  if (english_labels_ == english) {
    return;
  }
  english_labels_ = english;
  if (visible_ && window_) {
    Render();
  }
}

void NativeOrbitWindow::SetMoreBadge(bool visible) {
  if (more_badge_ == visible) {
    return;
  }
  more_badge_ = visible;
  if (visible_ && window_) {
    Render();
  }
}

void NativeOrbitWindow::SetExpanded(bool expanded) {
  if (expanded) {
    hide_when_collapsed_ = false;
  }
  if (expand_target_ == expanded && !expand_animating_) {
    return;  // already settled at the requested end state
  }
  expand_target_ = expanded;
  expand_start_progress_ = expand_progress_;
  expand_start_ms_ = GetTickCount64();
  expand_animating_ = true;
  if (anim_timer_id_ == 0 && window_) {
    anim_timer_id_ = SetTimer(window_, kAnimTimerId, 16, nullptr);
  }
  OnAnimationTick();
}

void NativeOrbitWindow::OnAnimationTick() {
  if (expand_animating_) {
    const double duration =
        expand_target_ ? kExpandDurationMs : kCollapseDurationMs;
    double raw = static_cast<double>(GetTickCount64() - expand_start_ms_) /
                 duration;
    if (raw < 0.0) raw = 0.0;
    if (raw > 1.0) raw = 1.0;
    const double eased = EaseOutCubic(raw);
    const double to = expand_target_ ? 1.0 : 0.0;
    expand_progress_ = expand_start_progress_ + (to - expand_start_progress_) * eased;
    if (raw >= 1.0) {
      expand_animating_ = false;
      expand_progress_ = to;
      if (anim_timer_id_ != 0 && window_) {
        KillTimer(window_, anim_timer_id_);
        anim_timer_id_ = 0;
      }
      if (!expand_target_ && hide_when_collapsed_) {
        Hide();
      }
    }
  }
  if (visible_) {
    Render();
  }
  // Keep the main ball's active opacity in sync with the constellation,
  // regardless of timer imprecision.
  if (ball_) {
    ball_->SetExpanded(expand_progress_);
  }
}

double NativeOrbitWindow::EaseOutCubic(double t) {
  const double inv = 1.0 - t;
  return 1.0 - inv * inv * inv;
}

void NativeOrbitWindow::MainBallPosition(double* out_x,
                                         double* out_y) const {
  if (ball_) {
    const NativeBallWindow::Geometry geometry = ball_->GetGeometry();
    *out_x = geometry.center_x;
    *out_y = geometry.center_y;
    return;
  }
  // Fallback: derive a stable center from the seed we received in Show.
  if (host_window_) {
    RECT host{};
    GetWindowRect(host_window_, &host);
    const double scale = (dpi_ > 0 ? dpi_ : 96.0) / 96.0;
    switch (dock_edge_) {
      case BallDockEdge::kLeft:
        *out_x = kBallCenterOffset;
        *out_y = (host.bottom - host.top) / 2.0 / scale;
        break;
      case BallDockEdge::kRight: {
        const double width_logical =
            (host.right - host.left) / scale;
        *out_x = width_logical - kBallCenterOffset;
        *out_y = (host.bottom - host.top) / 2.0 / scale;
        break;
      }
      case BallDockEdge::kTop:
        *out_x = (host.right - host.left) / 2.0 / scale;
        *out_y = kBallCenterOffset;
        break;
      case BallDockEdge::kBottom: {
        const double height_logical =
            (host.bottom - host.top) / scale;
        *out_x = (host.right - host.left) / 2.0 / scale;
        *out_y = height_logical - kBallCenterOffset;
        break;
      }
    }
    (void)seed_main_x_;
    (void)seed_main_y_;
    return;
  }
  *out_x = seed_main_x_;
  *out_y = seed_main_y_;
}

NativeOrbitWindow::ArcLayout NativeOrbitWindow::ComputeArcLayout(
    double main_x,
    double main_y,
    double host_w,
    double host_h,
    int item_count,
    double preferred_angle,
    double min_subball_diameter,
    double base_radius,
    double max_radius_factor) {
  ArcLayout layout{};
  layout.radius = base_radius;
  layout.start_angle = preferred_angle;
  layout.end_angle = preferred_angle;
  layout.center_angle = preferred_angle;
  layout.fits_safely = false;

  if (host_w <= 0.0 || host_h <= 0.0) {
    return layout;
  }
  if (item_count <= 0) {
    return layout;
  }

  // Safe-area insets. Horizontal uses just the sub-ball radius (no
  // label needs to clear the side edge) while vertical adds the label
  // height so the text rendered below each disc never clips.
  const double horizontal_inset = kSubBallRadius + 2.0;
  const double vertical_inset = kSubBallRadius + kLabelHeight;
  const double left = kScreenMargin + horizontal_inset;
  const double right = host_w - kScreenMargin - horizontal_inset;
  const double top = kScreenMargin + vertical_inset;
  const double bottom = host_h - kScreenMargin - vertical_inset;
  if (left >= right || top >= bottom) {
    return layout;
  }

  // Two-pass radius search. The first pass covers the visual norm
  // (base_radius..base_radius * max_radius_factor) and prefers the
  // smallest radius that satisfies the chord rule; the second pass only
  // kicks in for tight corners that need to ride the host diagonal.
  const double primary_min = base_radius * 0.6;
  const double primary_max =
      std::max(base_radius, base_radius * max_radius_factor);
  const double emergency_max = 350.0;

  double best_window = 0.0;
  double best_half_span = 0.0;
  double best_radius = base_radius;
  double best_center = preferred_angle;
  bool found_safe = false;

  // Probe [r] and return a populated layout if 6 sub-balls fit, or
  // update [best_*] tracking if not. Returns true once a fitting radius
  // is found so the caller can stop searching.
  auto try_radius = [&](double r) -> bool {
    const AnglePieceList pieces =
        SafeAnglePieces(main_x, main_y, r, left, right, top, bottom);
    if (pieces.empty()) return false;
    double centre = preferred_angle;
    double dir_window = DirectedWindow(pieces, centre);
    if (dir_window <= 0.0) {
      const AnglePiece widest = WidestPiece(pieces);
      centre = (widest.lo + widest.hi) / 2.0;
      dir_window = widest.hi - widest.lo;
    }
    if (dir_window <= 0.0) return false;
    const double step_safe =
        std::asin(std::min(1.0, min_subball_diameter / (2.0 * r)));
    const double min_total_span = 2.0 * step_safe * (item_count - 1);
    const double desired_span = std::min(kArcSpanRad, dir_window);
    const double actual_span = std::min(desired_span, dir_window);
    if (actual_span >= min_total_span) {
      layout.radius = r;
      layout.center_angle = centre;
      const double half_span = actual_span / 2.0;
      layout.start_angle = centre - half_span;
      layout.end_angle = centre + half_span;
      layout.fits_safely = true;
      return true;
    }
    if (dir_window > best_window) {
      best_window = dir_window;
      best_half_span = dir_window / 2.0;
      best_radius = r;
      best_center = centre;
      found_safe = true;
    }
    return false;
  };

  for (double r = primary_min; r <= primary_max + 0.5; r += 2.0) {
    if (try_radius(r)) return layout;
  }
  for (double r = primary_max; r < emergency_max; r += 2.0) {
    if (try_radius(r)) return layout;
  }

  if (found_safe) {
    layout.radius = best_radius;
    layout.center_angle = best_center;
    layout.start_angle = best_center - best_half_span;
    layout.end_angle = best_center + best_half_span;
    layout.fits_safely = false;
    return layout;
  }

  // Host is so small no radius produced a safe piece. Place sub-balls
  // directly opposite the preferred direction at the base radius and let
  // the caller accept whatever overflow happens.
  layout.start_angle = preferred_angle;
  layout.end_angle = preferred_angle;
  return layout;
}

void NativeOrbitWindow::SubBallTargetPosition(BallDockEdge edge,
                                              size_t index,
                                              double main_x,
                                              double main_y,
                                              double* out_x,
                                              double* out_y) const {
  const double host_w = host_width_logical_;
  const double host_h = host_height_logical_;
  const bool corner_mode = IsCornerMode(main_x, main_y, host_w, host_h);

  // Preferred direction: cardinal (edge-perpendicular) in normal mode, the
  // vector from the main ball toward the host geometric centre when the
  // ball is wedged into a corner. ComputeArcLayout will pivot to the
  // widest safe piece when this direction itself is blocked.
  double preferred = CenterAngleForEdge(edge);
  if (corner_mode) {
    preferred = std::atan2(host_h / 2.0 - main_y, host_w / 2.0 - main_x);
  }

  const size_t count = kActionCount;
  const ArcLayout layout = ComputeArcLayout(
      main_x, main_y, host_w, host_h, static_cast<int>(count), preferred,
      kSubBallDiameter, kOrbitRadius, kMaxRadiusFactor);

  const double fraction = count <= 1
                              ? 0.5
                              : static_cast<double>(index) /
                                    static_cast<double>(count - 1);
  const double angle =
      layout.start_angle + fraction * (layout.end_angle - layout.start_angle);

  *out_x = main_x + layout.radius * std::cos(angle);
  *out_y = main_y + layout.radius * std::sin(angle);
}

LRESULT CALLBACK NativeOrbitWindow::WndProc(HWND window,
                                            UINT message,
                                            WPARAM wparam,
                                            LPARAM lparam) noexcept {
  NativeOrbitWindow* orbit = reinterpret_cast<NativeOrbitWindow*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    orbit = static_cast<NativeOrbitWindow*>(create->lpCreateParams);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(orbit));
  }
  if (orbit) {
    return orbit->MessageHandler(window, message, wparam, lparam);
  }
  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT NativeOrbitWindow::MessageHandler(HWND window,
                                          UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam) noexcept {
  switch (message) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;

    case WM_MOVE:
    case WM_SIZE:
    case WM_WINDOWPOSCHANGED:
      // UpdateLayeredWindow composites the source DC to a fixed screen
      // position; when the window moves, the composite does NOT follow
      // unless we re-render. Re-render here so the constellation stays
      // glued to the host as it drags between edges.
      if (visible_) {
        Render();
      }
      return 0;

    case WM_NCHITTEST: {
      // Only the visible sub-balls should receive pointer input. The
      // surrounding pixels are fully transparent and must leave the
      // desktop usable while the constellation is open.
      POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(window, &point);
      RECT client{};
      GetClientRect(window, &client);
      const double scale_x = std::max(
          1.0, (client.right - client.left) / kLogicalOrbitWidth);
      const double scale_y = std::max(
          1.0, (client.bottom - client.top) / kLogicalOrbitHeight);
      return HitTestAction(point.x / scale_x, point.y / scale_y)
                 ? HTCLIENT
                 : HTTRANSPARENT;
    }

    case WM_MOUSEMOVE:
      if (!tracking_mouse_) {
        TRACKMOUSEEVENT tracking{};
        tracking.cbSize = sizeof(TRACKMOUSEEVENT);
        tracking.dwFlags = TME_LEAVE;
        tracking.hwndTrack = window;
        TrackMouseEvent(&tracking);
        tracking_mouse_ = true;
        Notify("enter");
      }
      {
        RECT client{};
        GetClientRect(window, &client);
        const double scale_x = std::max(
            1.0, (client.right - client.left) / kLogicalOrbitWidth);
        const double scale_y = std::max(
            1.0, (client.bottom - client.top) / kLogicalOrbitHeight);
        const int hovered_index = HitTestActionIndex(
            GET_X_LPARAM(lparam) / scale_x, GET_Y_LPARAM(lparam) / scale_y);
        if (hovered_action_index_ != hovered_index) {
          hovered_action_index_ = hovered_index;
          Render();
        }
      }
      return 0;

    case WM_MOUSELEAVE:
      tracking_mouse_ = false;
      if (hovered_action_index_ != -1) {
        hovered_action_index_ = -1;
        Render();
      }
      Notify("exit");
      return 0;

    case WM_LBUTTONUP: {
      RECT client{};
      GetClientRect(window, &client);
      const double scale_x = std::max(
          1.0, (client.right - client.left) / kLogicalOrbitWidth);
      const double scale_y = std::max(
          1.0, (client.bottom - client.top) / kLogicalOrbitHeight);
      const double x = GET_X_LPARAM(lparam) / scale_x;
      const double y = GET_Y_LPARAM(lparam) / scale_y;
      if (const char* action = HitTestAction(x, y)) {
        Notify(action);
      }
      return 0;
    }

    case WM_RBUTTONUP:
      Notify("more");
      return 0;

    case WM_ERASEBKGND:
      return 1;

    case WM_TIMER:
      if (wparam == kAnimTimerId) {
        OnAnimationTick();
      }
      return 0;

    case WM_USER + 100: {
      // Debug hook: dump the current orbit layout (host size, main ball
      // position, all 6 sub-ball target positions) to a known file so
      // out-of-process tooling (PowerShell regression tests) can assert
      // the corner-aware geometry. The file is small and short-lived; it
      // is overwritten on every call and lives in %TEMP%.
      char path[MAX_PATH];
      DWORD n = GetTempPathA(MAX_PATH, path);
      if (n > 0 && n < MAX_PATH) {
        strcat_s(path, "jianhe_orbit_layout.txt");
        FILE* f = nullptr;
        if (fopen_s(&f, path, "w") == 0 && f) {
          double mx = 0.0;
          double my = 0.0;
          MainBallPosition(&mx, &my);
          fprintf(f, "host=%.6f %.6f\n", host_width_logical_,
                  host_height_logical_);
          fprintf(f, "main=%.6f %.6f\n", mx, my);
          for (size_t i = 0; i < kActionCount; ++i) {
            double tx = 0.0;
            double ty = 0.0;
            SubBallTargetPosition(dock_edge_, i, mx, my, &tx, &ty);
            fprintf(f, "sub[%zu]=%.6f %.6f\n", i, tx, ty);
          }
          fclose(f);
        }
      }
      return 0;
    }
  }
  return DefWindowProc(window, message, wparam, lparam);
}

const char* NativeOrbitWindow::HitTestAction(double x, double y) const {
  const int index = HitTestActionIndex(x, y);
  return index >= 0 ? kActions[index].event : nullptr;
}

int NativeOrbitWindow::HitTestActionIndex(double x, double y) const {
  // Hit-test against each sub-ball's *target* position (not the animated
  // mid-flight position). During the expand / collapse the sub-balls are
  // in motion, so the user has to wait for them to settle; this keeps the
  // hit region stable and avoids phantom targets that move under the
  // pointer.
  double main_x = 0.0;
  double main_y = 0.0;
  MainBallPosition(&main_x, &main_y);
  const double r = kSubBallRadius + 2.0;
  const double r_sq = r * r;
  for (size_t index = 0; index < kActionCount; ++index) {
    double tx = 0.0;
    double ty = 0.0;
    SubBallTargetPosition(dock_edge_, index, main_x, main_y, &tx, &ty);
    const double dx = x - tx;
    const double dy = y - ty;
    if (dx * dx + dy * dy <= r_sq) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

void NativeOrbitWindow::Notify(const std::string& event) {
  if (callback_) {
    callback_(event);
  }
}

void NativeOrbitWindow::Render() {
  if (!window_ || gdiplus_token_ == 0) {
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
  // this, BI_RGB treats the 32bpp data as 0x00BBGGRR with the high
  // byte ignored, so the cleared "transparent" 0x00000000 pixels
  // come back as opaque black rectangles behind the constellation.
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
  HBITMAP bitmap_handle =
      CreateDIBSection(screen_dc, reinterpret_cast<BITMAPINFO*>(&dib),
                       DIB_RGB_COLORS, &raw_pixels, nullptr, 0);
  if (!bitmap_handle || !raw_pixels) {
    if (bitmap_handle) {
      DeleteObject(bitmap_handle);
    }
    DeleteDC(memory_dc);
    ReleaseDC(nullptr, screen_dc);
    return;
  }

  HGDIOBJ old_bitmap = SelectObject(memory_dc, bitmap_handle);
  // Transparent pixels stay transparent. WM_NCHITTEST limits interaction to
  // actual sub-balls, so there is no invisible full-window input layer.
  std::fill(static_cast<uint32_t*>(raw_pixels),
            static_cast<uint32_t*>(raw_pixels) + width * height, 0);

  Gdiplus::Bitmap surface(width, height, width * 4,
                          PixelFormat32bppPARGB,
                          static_cast<BYTE*>(raw_pixels));
  Gdiplus::Graphics graphics(&surface);
  graphics.SetCompositingMode(Gdiplus::CompositingModeSourceOver);
  graphics.SetCompositingQuality(Gdiplus::CompositingQualityHighQuality);
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
  graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
  const float scale_x =
      static_cast<float>(width / kLogicalOrbitWidth);
  const float scale_y =
      static_cast<float>(height / kLogicalOrbitHeight);
  graphics.ScaleTransform(scale_x, scale_y);

  // Resolve the live main ball center on every render so the constellation
  // stays anchored to the real ball position as the host moves.
  double main_x = 0.0;
  double main_y = 0.0;
  MainBallPosition(&main_x, &main_y);

  // 1. Compute per-sub-ball animated positions and progress (with stagger).
  SubBallRenderState states[kActionCount];
  for (size_t i = 0; i < kActionCount; ++i) {
    double tx = 0.0;
    double ty = 0.0;
    SubBallTargetPosition(dock_edge_, i, main_x, main_y, &tx, &ty);
    const double stagger = static_cast<double>(i) * kStaggerMs /
                           kExpandDurationMs;
    const double raw = expand_progress_ - stagger;
    double individual = 0.0;
    if (raw > 0.0) {
      individual = std::min(1.0, raw / std::max(0.0001, 1.0 - stagger));
    }
    individual = EaseOutCubic(individual);
    states[i].current_x = main_x + (tx - main_x) * individual;
    states[i].current_y = main_y + (ty - main_y) * individual;
    states[i].individual_progress = individual;
  }

  // 2. Sub-balls.
  for (size_t i = 0; i < kActionCount; ++i) {
    DrawSubBall(&graphics, states[i].current_x, states[i].current_y,
                kActions[i], i, states[i].individual_progress);
  }

  // 3. Update badge: a red dot with a paper rim at the top-right of the
  //    "more" sub-ball, fading in with the ball itself.
  if (more_badge_) {
    for (size_t i = 0; i < kActionCount; ++i) {
      if (std::strcmp(kActions[i].event, "more") != 0) {
        continue;
      }
      const double progress = states[i].individual_progress;
      if (progress <= 0.0) {
        break;
      }
      const BYTE alpha =
          static_cast<BYTE>(std::clamp(255.0 * progress, 0.0, 255.0));
      // 45 degrees up-right on the sub-ball's rim.
      const float offset = static_cast<float>(kSubBallRadius * 0.7071);
      const float bx = static_cast<float>(states[i].current_x) + offset;
      const float by = static_cast<float>(states[i].current_y) - offset;
      constexpr float kBadgeRadius = 6.0f;
      constexpr float kBadgeRim = 1.5f;
      Gdiplus::SolidBrush rim(Gdiplus::Color(alpha, 255, 247, 234));
      graphics.FillEllipse(&rim, bx - kBadgeRadius - kBadgeRim,
                           by - kBadgeRadius - kBadgeRim,
                           (kBadgeRadius + kBadgeRim) * 2.0f,
                           (kBadgeRadius + kBadgeRim) * 2.0f);
      Gdiplus::SolidBrush dot(Gdiplus::Color(alpha, 229, 72, 59));
      graphics.FillEllipse(&dot, bx - kBadgeRadius, by - kBadgeRadius,
                           kBadgeRadius * 2.0f, kBadgeRadius * 2.0f);
      break;
    }
  }

  // 4. Hover label. Keeping labels hidden until their sub-ball is hovered
  //    leaves the constellation uncluttered. The opaque dark chip preserves
  //    legibility over light, dark, or detailed desktop backgrounds.
  Gdiplus::Font label_font(L"Microsoft YaHei UI", 11.0f,
                           Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
  Gdiplus::StringFormat* format = CreateLabelFormat();
  for (size_t i = 0; i < kActionCount; ++i) {
    if (hovered_action_index_ != static_cast<int>(i)) {
      continue;
    }
    const double sub_progress = states[i].individual_progress;
    if (sub_progress < 0.5) {
      continue;
    }
    const double label_alpha = (sub_progress - 0.5) / 0.5;
    const Gdiplus::RectF label_rect = LabelRect(
        dock_edge_, states[i].current_x, states[i].current_y, i);
    const BYTE label_alpha_byte =
        static_cast<BYTE>(255.0 * label_alpha);
    const Gdiplus::RectF background_rect(
        label_rect.X - kLabelHorizontalPadding, label_rect.Y,
        label_rect.Width + kLabelHorizontalPadding * 2.0f, label_rect.Height);
    DrawRoundedRectangle(
        &graphics, background_rect, kLabelCornerRadius,
        Gdiplus::Color(label_alpha_byte, 20, 19, 17),
        Gdiplus::Color(0, 0, 0, 0), 0.0f);
    Gdiplus::SolidBrush label_brush(
        Gdiplus::Color(label_alpha_byte, 255, 255, 255));
    graphics.DrawString(english_labels_ ? kActions[i].english_label
                                        : kActions[i].label,
                        -1, &label_font, label_rect,
                        format, &label_brush);
  }
  delete format;

  // Commit all anti-aliased pixels to the premultiplied-alpha bitmap before
  // handing it to the layered-window compositor.
  graphics.Flush(Gdiplus::FlushIntentionSync);

  POINT destination{bounds.left, bounds.top};
  SIZE size{width, height};
  POINT source{0, 0};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(window_, screen_dc, &destination, &size, memory_dc,
                      &source, 0, &blend, ULW_ALPHA);

  SelectObject(memory_dc, old_bitmap);
  DeleteObject(bitmap_handle);
  DeleteDC(memory_dc);
  ReleaseDC(nullptr, screen_dc);
}
