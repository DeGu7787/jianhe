#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <windows.h>
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "native_ball_window.h"
#include "native_orbit_window.h"
#include "win32_window.h"

// Sent by a second launch attempt after it detects the running process.
constexpr UINT kJianHeActivateExistingInstanceMessage = WM_APP + 71;
constexpr UINT kJianHeBackgroundSyncMessage = WM_APP + 72;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool background_sync = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;
  bool background_sync_ = false;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  std::unique_ptr<NativeBallWindow> native_ball_;
  std::unique_ptr<NativeOrbitWindow> native_orbit_;
  bool wake_hot_key_registered_ = false;
  UINT wake_hot_key_modifiers_ = MOD_CONTROL | MOD_SHIFT;
  UINT wake_hot_key_virtual_key_ = VK_SPACE;

  // Recomputes and applies the D3D child's clip region from the current
  // ball edge and window size. Cheap enough to call on every dock change;
  // called from the setSize handler and from the ball's DockChangedCallback
  // so the panel stays aligned when the user drags the ball while a panel
  // is open. The explicit visibility value lets callers install the region
  // before exposing the host, avoiding a full-window intermediate frame.
  // Safe to call before the D3D child is available.
  void UpdatePanelRegion(bool panel_visible, bool redraw = true,
                         bool update_host = true, bool update_d3d = true);

  // Fades the already-rendered, clipped Flutter host in at the compositor
  // level. This keeps the D3D frame stable while avoiding a hard alpha jump.
  void StartPanelFadeIn();
  void StopPanelFade(bool finish_visible);
  void OnPanelFadeTick();

  // Reports the current host client size (logical px) to Dart whenever it
  // changed while a panel is visible, so the Flutter layout follows a user
  // edge resize in real time. Suppressed for sizes that were not touched.
  void NotifyPanelSizeChanged();
  void SchedulePanelSizeChanged();
  void TryCompletePanelResizeUpdate();

  // A scheduled launch can reach the native foreground window before Dart has
  // subscribed to window events. Keep one coalesced request until Dart
  // announces that its listener is ready.
  void DispatchPendingBackgroundSync();

  // X-button/quit close requests are held until Dart has flushed in-memory
  // state (an unsaved editor draft) and confirms via the window channel. The
  // watchdog timer bounds how long an unresponsive engine can delay it.
  enum class CloseRequestState { kIdle, kWaiting, kSettled };
  void SettleCloseRequest();
  void OnCloseRequestReply();
  CloseRequestState close_request_state_ = CloseRequestState::kIdle;

  UINT_PTR panel_fade_timer_id_ = 0;
  ULONGLONG panel_fade_start_ms_ = 0;
  double in_flight_panel_width_ = -1.0;
  double in_flight_panel_height_ = -1.0;
  UINT_PTR panel_resize_timer_id_ = 0;
  bool panel_resize_active_ = false;
  bool panel_resize_update_in_flight_ = false;
  bool panel_resize_frame_drawn_ = false;
  bool panel_resize_dart_acknowledged_ = false;
  bool background_sync_dart_ready_ = false;
  bool background_sync_pending_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
