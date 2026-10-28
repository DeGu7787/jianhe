#ifndef RUNNER_NATIVE_BALL_WINDOW_H_
#define RUNNER_NATIVE_BALL_WINDOW_H_

#include <windows.h>

#include <functional>
#include <string>

#include "win32_window.h"

// A small, childless layered window used for the floating ball. It is rendered
// with premultiplied per-pixel alpha so its circular edge remains smooth on any
// desktop background. The host window is docked against one of the four screen
// edges and the ball stays fully inside the host, so the ball is never clipped
// by the screen while it snaps to the nearest edge.
class NativeBallWindow {
 public:
  using EventCallback = std::function<void(const std::string&)>;

  // Fired when the docked screen edge changes (e.g. after a drag snaps to
  // a new edge). The argument is the new edge. Used by FlutterWindow to
  // refresh the panel clip region in real time when the user drags the
  // ball while a panel is open.
  using DockChangedCallback = std::function<void(BallDockEdge)>;

  // Geometry reported back to Flutter so the action menu can anchor to the real
  // ball position inside the (possibly enlarged) host window.
  struct Geometry {
    BallDockEdge edge = BallDockEdge::kRight;
    double offset = 0.0;  // ball position along the work-area edge, logical px
    double center_x = 0.0;  // host-relative ball center, logical px
    double center_y = 0.0;
  };

  NativeBallWindow();
  ~NativeBallWindow();

  bool Create(HWND host_window, EventCallback callback);
  void Destroy();

  // Docks the host window to the current edge and places the ball inside it at
  // the current offset. Keeps the ball fully inside the work area.
  void PositionForHost();

  // Updates the docked edge and the position along the edge (logical px).
  void SetDock(BallDockEdge edge, double offset);

  // Registers a callback that fires when the docked edge changes. Passing
  // a default-constructed callback clears the previous registration. The
  // callback is invoked synchronously from the same thread that changed
  // the edge (typically the UI thread).
  void SetDockChangedCallback(DockChangedCallback callback);

  // Shows the ball without activating the Flutter host window.
  void Show();

  // Sets the main ball's activation progress in [0, 1]. The orbit window
  // normally drives this via SetBall(), so Dart only needs to call the
  // orbit's SetExpanded().
  void SetExpanded(double progress);

  BallDockEdge edge() const { return edge_; }
  double offset() const { return offset_; }
  double expand_progress() const { return expand_progress_; }

  Geometry GetGeometry() const;

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
  void SetHovered(bool hovered);
  BallDockEdge SnapToNearestEdge();
  void Notify(const std::string& event);
  HWND window_ = nullptr;
  HWND host_window_ = nullptr;
  EventCallback callback_;
  bool hovered_ = false;
  bool tracking_mouse_ = false;
  bool pointer_down_ = false;
  bool dragging_ = false;
  bool drag_start_notified_ = false;
  bool positioned_once_ = false;
  double expand_progress_ = 0.0;
  BallDockEdge edge_ = BallDockEdge::kRight;
  double offset_ = 0.0;
  POINT drag_start_cursor_{};
  RECT drag_start_window_{};
  UINT dpi_ = 96;
  DockChangedCallback dock_changed_callback_;
};

#endif  // RUNNER_NATIVE_BALL_WINDOW_H_
