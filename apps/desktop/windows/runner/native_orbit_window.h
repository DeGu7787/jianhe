#ifndef RUNNER_NATIVE_ORBIT_WINDOW_H_
#define RUNNER_NATIVE_ORBIT_WINDOW_H_

#include <windows.h>

#include <functional>
#include <string>

#include "native_ball_window.h"
#include "win32_window.h"

// Per-pixel-alpha window for the constellation of action sub-balls around the
// floating ball. The native orbit drives its own expand / collapse animation
// (staggered, ease-out-cubic) so the Dart side can stay fire-and-forget. When
// the orbit expands, it also reports the current progress to the main ball so
// its active opacity stays synchronized. The constellation keeps the main ball
// as the visible "hub" of the action list.
class NativeOrbitWindow {
 public:
  using EventCallback = std::function<void(const std::string&)>;

  NativeOrbitWindow();
  ~NativeOrbitWindow();

  bool Create(HWND host_window, EventCallback callback);
  void Destroy();

  // Show the constellation with the main ball at the given host-relative
  // logical-pixel position. The position is overwritten on every render
  // by reading the NativeBallWindow's geometry, so this is only the initial
  // seed used before the first render tick.
  void Show(BallDockEdge edge, double main_x, double main_y);
  void Hide();
  // Keeps the layered orbit alive until its self-driven collapse reaches the
  // main ball, then hides the window without an abrupt final frame.
  void HideAfterCollapse();
  void PositionForHost(BallDockEdge edge);
  bool is_visible() const { return visible_; }

  // Starts a self-running expand or collapse animation. Calling with the
  // current end state is a no-op; calling with the opposite state reverses
  // the animation from the current progress (no snap).
  void SetExpanded(bool expanded);

  // Switches the hover labels between Chinese and English (the app's
  // interface language, sent from Dart through "setLanguage").
  void SetEnglishLabels(bool english);

  // Shows or hides the red dot on the "more" sub-ball (a new app version is
  // waiting for the user, sent from Dart through "setMoreBadge").
  void SetMoreBadge(bool visible);

  // Injects a pointer to the main ball so the orbit can keep its active opacity
  // in sync with the constellation's expand progress.
  void SetBall(NativeBallWindow* ball) { ball_ = ball; }

  static LRESULT CALLBACK WndProc(HWND window,
                                  UINT message,
                                  WPARAM wparam,
                                  LPARAM lparam) noexcept;

 private:
  LRESULT MessageHandler(HWND window,
                         UINT message,
                         WPARAM wparam,
                         LPARAM lparam) noexcept;

  void Render();
  void Notify(const std::string& event);
  const char* HitTestAction(double x, double y) const;
  int HitTestActionIndex(double x, double y) const;
  void OnAnimationTick();

  // Resolves the host-relative logical-pixel position of the main ball.
  // Prefers the live NativeBallWindow geometry; falls back to the value
  // passed in Show() if the ball is not available.
  void MainBallPosition(double* out_x, double* out_y) const;

  // Returns the target host-relative position of the i-th sub-ball around
  // the main ball at the given center. The sub-ball geometry is shared
  // between the normal arc and the corner-aware two-ring layout; both
  // paths consult the same angle-constrained arc layout.
  void SubBallTargetPosition(BallDockEdge edge,
                             size_t index,
                             double main_x,
                             double main_y,
                             double* out_x,
                             double* out_y) const;

  static double EaseOutCubic(double t);

  // Per-sub-ball layout produced by ComputeArcLayout. Each sub-ball is
  // placed at (main_x + radius * cos(angle), main_y + radius * sin(angle))
  // with the angles spread evenly across [start_angle, end_angle].
  struct ArcLayout {
    double radius;
    double start_angle;
    double end_angle;
    double center_angle;
    bool fits_safely;  // false when 6 balls could not be placed without
                       // overlap; the caller should accept the visual
                       // squeeze rather than overflow the host.
  };

  // Computes the angle-constrained arc layout for the sub-balls. The
  // algorithm (ported from Dart ball_arc_calculator.dart) intersects the
  // four screen-edge constraints, picks the widest safe angular window
  // that can hold [item_count] sub-balls with the minimum chord length
  // defined by [min_subball_diameter], and centres the window on
  // [preferred_angle] (falling back to the widest piece's midpoint when
  // the preferred direction itself is blocked).
  static ArcLayout ComputeArcLayout(double main_x,
                                    double main_y,
                                    double host_w,
                                    double host_h,
                                    int item_count,
                                    double preferred_angle,
                                    double min_subball_diameter,
                                    double base_radius,
                                    double max_radius_factor);

  HWND window_ = nullptr;
  HWND host_window_ = nullptr;
  EventCallback callback_;
  bool visible_ = false;
  BallDockEdge dock_edge_ = BallDockEdge::kRight;
  bool tracking_mouse_ = false;
  int hovered_action_index_ = -1;
  bool english_labels_ = false;
  bool more_badge_ = false;
  UINT dpi_ = 96;
  ULONG_PTR gdiplus_token_ = 0;
  NativeBallWindow* ball_ = nullptr;

  // Cached host-window size in logical pixels. Refreshed by PositionForHost
  // and read by SubBallTargetPosition to detect when the main ball is
  // sitting in a host corner. A value of 0 means "not yet measured" and
  // makes the corner detector fall back to the single-arc layout.
  double host_width_logical_ = 0.0;
  double host_height_logical_ = 0.0;

  // Initial / fallback position of the main ball (set in Show). Once the
  // ball pointer is set, Render reads the live position from it.
  double seed_main_x_ = 0.0;
  double seed_main_y_ = 0.0;

  // Animation state. The orbit runs a 60 Hz timer so the expand / collapse
  // is self-driven and survives without per-frame Dart calls.
  bool expand_target_ = false;        // requested end state
  bool expand_animating_ = false;     // true while a transition is running
  ULONGLONG expand_start_ms_ = 0;     // GetTickCount64 at the start of the
                                      // current transition
  double expand_start_progress_ = 0.0;  // progress at the start of the
                                        // current transition
  double expand_progress_ = 0.0;      // 0 = fully collapsed, 1 = fully open
  UINT_PTR anim_timer_id_ = 0;
  bool hide_when_collapsed_ = false;
};

#endif  // RUNNER_NATIVE_ORBIT_WINDOW_H_
