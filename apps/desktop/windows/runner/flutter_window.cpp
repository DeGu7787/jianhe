#include "flutter_window.h"

#include "background_sync_handoff.h"
#include "background_sync_task_scheduler.h"
#include "installer_language_handoff.h"
#include "utils.h"

#include <cmath>
#include <optional>

#include "flutter/generated_plugin_registrant.h"

#include <commctrl.h>
#include <flutter/method_result_functions.h>
#include <shellapi.h>

namespace {

constexpr UINT_PTR kPanelFadeTimerId = 41;
constexpr UINT_PTR kPanelResizeTimerId = 42;
constexpr UINT_PTR kCloseRequestTimerId = 43;
constexpr double kPanelFadeDurationMs = 180.0;
constexpr UINT kCloseRequestTimeoutMs = 4000;
constexpr int kWakeHotKeyId = 1;

double EaseOutCubic(double value) {
  const double inverse = 1.0 - value;
  return 1.0 - inverse * inverse * inverse;
}

HBRUSH PaperBrush() {
  static const HBRUSH brush = CreateSolidBrush(RGB(0xFF, 0xFC, 0xF5));
  return brush;
}

std::wstring Utf16FromUtf8(const std::string& value) {
  if (value.empty()) return std::wstring();
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                          value.data(),
                                          static_cast<int>(value.size()),
                                          nullptr, 0);
  if (length <= 0) return std::wstring();
  std::wstring result(length, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) == 0) {
    return std::wstring();
  }
  return result;
}

// The Flutter view is rendered through D3D into a child window whose GDI
// backing store is empty, so DefWindowProc's hit test reports HTNOWHERE and
// clicks on the menu buttons fall through to the windows below. Subclass the
// view window to claim the client area; the Flutter engine performs its own
// render-tree hit testing on the pointer events.
LRESULT CALLBACK FlutterViewSubclassProc(HWND hwnd,
                                         UINT message,
                                         WPARAM wparam,
                                         LPARAM lparam,
                                         UINT_PTR subclass_id,
                                         DWORD_PTR ref_data) {
  if (message == WM_NCHITTEST) {
    return HTCLIENT;
  }
  if (message == WM_ERASEBKGND) {
    // ANGLE's swap chain ignores the per-pixel alpha and presents the clear
    // colour (opaque black) on the first frame after a resize. That is what
    // produces the ~1 second black flash when a panel stage opens: the D3D
    // child becomes visible, the swap chain is rebuilt and shows black, and
    // only after Flutter has produced a panel frame does the real content
    // replace it. Painting the paper colour in WM_ERASEBKGND makes the
    // first paint match the panel background so the flash disappears (the
    // ANGLE swap chain output is opaque and still wins once it is ready, so
    // this is purely a placeholder colour that lasts one or two frames).
    HDC hdc = reinterpret_cast<HDC>(wparam);
    RECT client{};
    GetClientRect(hwnd, &client);
    FillRect(hdc, &client, PaperBrush());
    return 1;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

BallDockEdge EdgeFromName(const std::string& name) {
  if (name == "left") {
    return BallDockEdge::kLeft;
  }
  if (name == "top") {
    return BallDockEdge::kTop;
  }
  if (name == "bottom") {
    return BallDockEdge::kBottom;
  }
  return BallDockEdge::kRight;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool background_sync)
    : project_(project), background_sync_(background_sync) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Make the D3D-rendered view window hit-testable (see
  // FlutterViewSubclassProc above).
  SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                    FlutterViewSubclassProc, 0, 0);

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "jianhe/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "backgroundSyncReady") {
          background_sync_dart_ready_ = true;
          if (ConsumeBackgroundSyncPending()) {
            background_sync_pending_ = true;
          }
          result->Success();
          DispatchPendingBackgroundSync();
          return;
        }
        if (call.method_name() == "setLanguage") {
          const auto* language = std::get_if<std::string>(call.arguments());
          const bool english = language && *language == "en";
          if (native_orbit_) native_orbit_->SetEnglishLabels(english);
          SetBackgroundSyncTaskEnglish(english);
          result->Success();
          return;
        }
        if (call.method_name() == "setMoreBadge") {
          const auto* visible = std::get_if<bool>(call.arguments());
          if (native_orbit_) native_orbit_->SetMoreBadge(visible && *visible);
          result->Success();
          return;
        }
        if (call.method_name() == "consumeInstallerLanguage") {
          const std::string language = ConsumeInstallerLanguage();
          result->Success(language.empty()
                              ? flutter::EncodableValue()
                              : flutter::EncodableValue(language));
          return;
        }
        if (call.method_name() == "setSize") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!arguments) {
            result->Error("invalid_arguments", "Expected a size map.");
            return;
          }
          const auto width_it =
              arguments->find(flutter::EncodableValue("width"));
          const auto height_it =
              arguments->find(flutter::EncodableValue("height"));
          if (width_it == arguments->end() || height_it == arguments->end()) {
            result->Error("invalid_arguments", "Width and height are required.");
            return;
          }
          const double width = std::get<double>(width_it->second);
          const double height = std::get<double>(height_it->second);
          // The Dart side also sends a `stage` name (one of
          // `BallWindowStage` in ball_window_controller.dart) so the C++
          // layer can pick the right native/Flutter surface for the stage
          // without guessing from the size alone (collapsed and a hypothetical
          // small future panel would both be 88x88, menu and panels are all
          // > 88x88).
          std::string stage_name;
          const auto stage_it =
              arguments->find(flutter::EncodableValue("stage"));
          if (stage_it != arguments->end()) {
            stage_name = std::get<std::string>(stage_it->second);
          }
          const BallDockEdge edge =
              native_ball_ ? native_ball_->edge() : BallDockEdge::kRight;
          const double offset = native_ball_ ? native_ball_->offset() : 0.0;
          const bool is_menu = (stage_name == "menu");
          const bool is_collapsed = (stage_name == "collapsed");
          const bool is_panel =
              !is_menu && !is_collapsed && (width > 88.0 || height > 88.0);
          // The D3D-rendered Flutter view is the source of the "黑底" problem:
          // ANGLE on Windows ignores the swap chain's per-pixel alpha, so the
          // surface is composited as a flat opaque rectangle. The native
          // orbit (menu) and native ball (collapsed) are layered per-pixel
          // alpha windows that already render correctly with the desktop
          // behind them, so we let the host stay transparent (alpha=0) in
          // those stages and the D3D child is composited invisibly with the
          // host. The panel stages need the D3D child because that is the
          // only way the Flutter panel UI is drawn - for those stages the
          // host becomes opaque and a SetWindowRgn on both the host and the
          // D3D child clips the visible area to the panel rect.
          //
          // Entering a panel is a two-phase transition: install the panel
          // region while the host is still transparent, then expose it. If
          // SetPanelVisible(true) runs first, its synchronous redraw lets DWM
          // composite one full rectangular D3D frame before the region is
          // installed, which is perceived as a flash. On exit, make the host
          // transparent first and only then clear the obsolete region.
          if (is_panel) {
            ResizeDocked(static_cast<unsigned int>(width),
                         static_cast<unsigned int>(height), edge, offset);
            UpdatePanelRegion(true);
            StartPanelFadeIn();
          } else {
            // Hide the opaque D3D host before resizing it. Resizing rebuilds
            // ANGLE's swap chain synchronously; if the host is still visible,
            // DWM can composite its dark clear frame for one refresh and the
            // user sees a black flash while collapsing the panel.
            StopPanelFade(false);
            SetPanelVisible(false);
            UpdatePanelRegion(false);
            ResizeDocked(static_cast<unsigned int>(width),
                         static_cast<unsigned int>(height), edge, offset);
          }
          HWND d3d_view = flutter_controller_->view()->GetNativeWindow();
          if (d3d_view) {
            // Keep the D3D child visible across every stage. In native-ball
            // mode the host is fully transparent (alpha=0) in the menu and
            // collapsed stages so the D3D surface is composited with the
            // host's alpha and the user cannot see it; keeping it shown
            // avoids a visible black flash when entering a panel stage
            // (the ANGLE render thread is not torn down on a stage switch,
            // and the swap chain is not freshly cleared from SW_HIDE on the
            // first paint).
            ShowWindow(d3d_view, SW_SHOWNOACTIVATE);
          }
          // In the menu stage the host sits at the same position as the
          // native orbit. Hiding the host (SW_HIDE) was found to confuse
          // DWM's z-order at that position: the orbit's pixels would not
          // be composited to the screen even with HWND_TOPMOST. Instead we
          // keep the host "visible" but fully transparent (alpha=0); the
          // orbit (also HWND_TOPMOST) sits on top of an invisible host.
          if (native_orbit_) {
            if (is_menu) {
              // The action list is a constellation of sub-balls arranged in
              // an arc around the main ball. Pass the main ball's actual
              // host-relative center so the arc anchors to the right pixel
              // even before the orbit's first render tick.
              const NativeBallWindow::Geometry main_geometry =
                  native_ball_ ? native_ball_->GetGeometry()
                               : NativeBallWindow::Geometry{};
              native_orbit_->PositionForHost(edge);
              native_orbit_->Show(edge, main_geometry.center_x,
                                  main_geometry.center_y);
            } else {
              // Dart lets the shortened collapse finish before resizing the
              // host. Hide at progress=0; if an unusual caller skipped that
              // wait, this still completes the collapse instead of snapping.
              native_orbit_->HideAfterCollapse();
            }
          }
          if (native_ball_) {
            native_ball_->PositionForHost();
            native_ball_->Show();
          }
          if (is_panel && flutter_controller_) {
            flutter_controller_->ForceRedraw();
          }
          result->Success(
              flutter::EncodableValue(std::string(BallDockEdgeName(edge))));
          return;
        }
        if (call.method_name() == "startDrag") {
          BallDockEdge edge = BallDockEdge::kRight;
          double offset = 0.0;
          DragAndSnap(&edge, &offset);
          if (native_ball_) {
            native_ball_->SetDock(edge, offset);
            native_ball_->PositionForHost();
            native_ball_->Show();
          }
          result->Success(
              flutter::EncodableValue(std::string(BallDockEdgeName(edge))));
          return;
        }
        if (call.method_name() == "beginPanelResize") {
          // Dart pressed a panel resize grip. Enter the system modal size
          // loop with the matching hit-test code, exactly like DragAndSnap
          // does for HTCAPTION moves. The loop runs inside this SendMessage
          // call: WM_SIZING/WM_SIZE keep the D3D child and the panel clip in
          // sync, WM_ENTERSIZEMOVE/WM_EXITSIZEMOVE bracket the interaction
          // for Dart, and the method returns when the user releases.
          std::string edge_name;
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments) {
            const auto edge_it =
                arguments->find(flutter::EncodableValue("edge"));
            if (edge_it != arguments->end()) {
              edge_name = std::get<std::string>(edge_it->second);
            }
          }
          UINT hit_test = 0;
          if (edge_name == "left") {
            hit_test = HTLEFT;
          } else if (edge_name == "right") {
            hit_test = HTRIGHT;
          } else if (edge_name == "top") {
            hit_test = HTTOP;
          } else if (edge_name == "bottom") {
            hit_test = HTBOTTOM;
          } else if (edge_name == "topLeft") {
            hit_test = HTTOPLEFT;
          } else if (edge_name == "topRight") {
            hit_test = HTTOPRIGHT;
          } else if (edge_name == "bottomLeft") {
            hit_test = HTBOTTOMLEFT;
          } else if (edge_name == "bottomRight") {
            hit_test = HTBOTTOMRIGHT;
          }
          if (hit_test != 0) {
            POINT cursor{};
            GetCursorPos(&cursor);
            ReleaseCapture();
            // WM_NCLBUTTONDOWN expects the pointer's screen coordinates in
            // lParam. Passing 0 happens to work for one-axis grips, but makes
            // Windows initialise corner tracking from the wrong point and can
            // collapse a diagonal drag to a single axis.
            SendMessage(GetHandle(), WM_NCLBUTTONDOWN, hit_test,
                        MAKELPARAM(cursor.x, cursor.y));
          }
          result->Success();
          return;
        }
        if (call.method_name() == "panelFrameReady") {
          // Dart calls this after laying out and painting the one size that is
          // currently in flight. Combined with the engine's one-shot frame
          // callback below, this forms a two-signal barrier without forcing an
          // extra frame or registering overlapping callbacks.
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!arguments || !panel_resize_update_in_flight_) {
            result->Success();
            return;
          }
          const auto width_it =
              arguments->find(flutter::EncodableValue("width"));
          const auto height_it =
              arguments->find(flutter::EncodableValue("height"));
          if (width_it == arguments->end() || height_it == arguments->end()) {
            result->Success();
            return;
          }
          const double width = std::get<double>(width_it->second);
          const double height = std::get<double>(height_it->second);
          if (std::abs(width - in_flight_panel_width_) < 0.5 &&
              std::abs(height - in_flight_panel_height_) < 0.5) {
            panel_resize_dart_acknowledged_ = true;
            TryCompletePanelResizeUpdate();
          }
          result->Success();
          return;
        }
        if (call.method_name() == "getBallLayout") {
          if (!native_ball_) {
            result->Success();
            return;
          }
          const NativeBallWindow::Geometry geometry = native_ball_->GetGeometry();
          flutter::EncodableMap layout;
          layout[flutter::EncodableValue("edge")] =
              flutter::EncodableValue(std::string(BallDockEdgeName(geometry.edge)));
          layout[flutter::EncodableValue("ballX")] =
              flutter::EncodableValue(geometry.center_x);
          layout[flutter::EncodableValue("ballY")] =
              flutter::EncodableValue(geometry.center_y);
          layout[flutter::EncodableValue("offset")] =
              flutter::EncodableValue(geometry.offset);
          result->Success(flutter::EncodableValue(layout));
          return;
        }
        if (call.method_name() == "setExpanded") {
          // The Dart side still sends a bool for back-compat with the
          // existing controller API, but both native windows now react to
          // it: the orbit drives the animation and keeps the main ball's
          // active opacity in sync. Calling SetExpanded(false) on the main ball
          // directly is harmless because the orbit will overwrite it on
          // its next tick anyway.
          bool expanded = false;
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments) {
            const auto expanded_it =
                arguments->find(flutter::EncodableValue("expanded"));
            if (expanded_it != arguments->end()) {
              expanded = std::get<bool>(expanded_it->second);
            }
          }
          if (native_orbit_) {
            native_orbit_->SetExpanded(expanded);
          } else if (native_ball_) {
            // Fallback when the orbit is unavailable (e.g. unit tests).
            native_ball_->SetExpanded(expanded ? 1.0 : 0.0);
          }
          result->Success();
          return;
        }
        if (call.method_name() == "setInitialPosition") {
          BallDockEdge edge = BallDockEdge::kRight;
          double offset = 0.0;
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments) {
            const auto edge_it = arguments->find(flutter::EncodableValue("edge"));
            if (edge_it != arguments->end()) {
              edge = EdgeFromName(std::get<std::string>(edge_it->second));
            }
            const auto offset_it =
                arguments->find(flutter::EncodableValue("offset"));
            if (offset_it != arguments->end()) {
              offset = std::get<double>(offset_it->second);
            }
          }
          if (native_ball_) {
            native_ball_->SetDock(edge, offset);
            native_ball_->PositionForHost();
            native_ball_->Show();
          }
          result->Success();
          return;
        }
        if (call.method_name() == "setWakeHotKey") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!arguments) {
            result->Error("invalid_arguments", "Expected a hotkey map.");
            return;
          }
          const auto modifiers_it =
              arguments->find(flutter::EncodableValue("modifiers"));
          const auto virtual_key_it =
              arguments->find(flutter::EncodableValue("virtualKey"));
          if (modifiers_it == arguments->end() ||
              virtual_key_it == arguments->end()) {
            result->Error("invalid_arguments",
                          "Modifiers and virtualKey are required.");
            return;
          }
          const UINT modifiers =
              static_cast<UINT>(std::get<int32_t>(modifiers_it->second));
          const UINT virtual_key =
              static_cast<UINT>(std::get<int32_t>(virtual_key_it->second));
          if (modifiers == 0 || virtual_key == 0 || virtual_key > 0xFF) {
            result->Error("invalid_hotkey", "Unsupported global hotkey.");
            return;
          }

          if (wake_hot_key_registered_ &&
              modifiers == wake_hot_key_modifiers_ &&
              virtual_key == wake_hot_key_virtual_key_) {
            result->Success(flutter::EncodableValue(true));
            return;
          }

          const UINT previous_modifiers = wake_hot_key_modifiers_;
          const UINT previous_virtual_key = wake_hot_key_virtual_key_;
          const bool had_previous = wake_hot_key_registered_;
          if (had_previous) {
            UnregisterHotKey(GetHandle(), kWakeHotKeyId);
            wake_hot_key_registered_ = false;
          }

          if (RegisterHotKey(GetHandle(), kWakeHotKeyId, modifiers,
                             virtual_key) != FALSE) {
            wake_hot_key_modifiers_ = modifiers;
            wake_hot_key_virtual_key_ = virtual_key;
            wake_hot_key_registered_ = true;
            result->Success(flutter::EncodableValue(true));
            return;
          }

          // Registration is transactional from the user's perspective. If
          // Windows rejects the new binding, restore the previously working
          // one and report failure so Dart does not persist the rejected value.
          if (had_previous) {
            wake_hot_key_registered_ =
                RegisterHotKey(GetHandle(), kWakeHotKeyId,
                               previous_modifiers,
                               previous_virtual_key) != FALSE;
          }
          result->Success(flutter::EncodableValue(false));
          return;
        }
        if (call.method_name() == "openExternalUrl") {
          const auto* url = std::get_if<std::string>(call.arguments());
          if (!url || url->rfind("https://", 0) != 0) {
            result->Error("invalid_url", "Only HTTPS URLs are supported.");
            return;
          }
          const std::wstring wide_url = Utf16FromUtf8(*url);
          if (wide_url.empty()) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          const HINSTANCE opened = ShellExecuteW(
              GetHandle(), L"open", wide_url.c_str(), nullptr, nullptr,
              SW_SHOWNORMAL);
          result->Success(flutter::EncodableValue(
              reinterpret_cast<INT_PTR>(opened) > 32));
          return;
        }
        if (call.method_name() == "quit") {
          PostMessage(GetHandle(), WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        if (call.method_name() == "confirmClose") {
          if (close_request_state_ == CloseRequestState::kWaiting) {
            SettleCloseRequest();
            // Destroy via the message loop, not inside this engine dispatch
            // callback: tearing the engine down from within its own
            // messenger callback would free objects still on the stack.
            PostMessage(GetHandle(), WM_CLOSE, 0, 0);
          }
          result->Success();
          return;
        }
        if (call.method_name() == "configureBackgroundSync") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!arguments) {
            result->Error("invalid_arguments", "Expected a schedule map.");
            return;
          }
          const auto mode_it = arguments->find(flutter::EncodableValue("mode"));
          if (mode_it == arguments->end()) {
            result->Error("invalid_arguments", "Schedule mode is required.");
            return;
          }
          BackgroundSyncSchedule schedule;
          schedule.daily = std::get<std::string>(mode_it->second) == "daily";
          const auto read_int = [&](const char* key, int fallback) {
            const auto it = arguments->find(flutter::EncodableValue(key));
            if (it == arguments->end()) return fallback;
            if (const auto* value = std::get_if<int32_t>(&it->second)) {
              return static_cast<int>(*value);
            }
            if (const auto* value = std::get_if<int64_t>(&it->second)) {
              return static_cast<int>(*value);
            }
            return fallback;
          };
          schedule.interval_minutes = read_int("intervalMinutes", 15);
          schedule.daily_hour = read_int("dailyHour", 21);
          schedule.daily_minute = read_int("dailyMinute", 0);
          if ((!schedule.daily && schedule.interval_minutes != 15 &&
               schedule.interval_minutes != 30 &&
               schedule.interval_minutes != 60) ||
              (schedule.daily &&
               (schedule.daily_hour < 0 || schedule.daily_hour > 23 ||
                schedule.daily_minute < 0 || schedule.daily_minute > 59))) {
            result->Error("invalid_arguments", "Invalid sync schedule.");
            return;
          }
          std::wstring next_run;
          std::wstring error;
          if (!ConfigureBackgroundSyncTask(schedule, &next_run, &error)) {
            result->Error("task_scheduler_error", Utf8FromUtf16(error.c_str()));
            return;
          }
          result->Success(
              flutter::EncodableValue(Utf8FromUtf16(next_run.c_str())));
          return;
        }
        if (call.method_name() == "cancelBackgroundSync") {
          std::wstring error;
          if (!CancelBackgroundSyncTask(&error)) {
            result->Error("task_scheduler_error", Utf8FromUtf16(error.c_str()));
            return;
          }
          result->Success();
          return;
        }
        if (call.method_name() == "completeBackgroundSync") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          int exit_code = 1;
          if (arguments) {
            const auto it =
                arguments->find(flutter::EncodableValue("exitCode"));
            if (it != arguments->end()) {
              if (const auto* value32 = std::get_if<int32_t>(&it->second)) {
                exit_code = static_cast<int>(*value32);
              } else if (const auto* value64 =
                             std::get_if<int64_t>(&it->second)) {
                exit_code = static_cast<int>(*value64);
              }
            }
          }
          result->Success();
          PostQuitMessage(exit_code);
          return;
        }
        result->NotImplemented();
      });

  // The native GDI+ ball and orbit windows are gated behind the
  // JIANHE_USE_NATIVE_BALL compile flag (defined via CMake target_compile_
  // definitions so the same value is visible to win32_window.cpp and
  // main.cpp). When the flag is 0 the desktop build matches the Web dev
  // build, which uses the in-Flutter arc menu only (NoopBallWindowController);
  // when it is 1 the GDI+ native ball/orbit windows paint the sub-ball
  // constellation and the host stays fully transparent.
#if JIANHE_USE_NATIVE_BALL
  if (!background_sync_) {
    native_ball_ = std::make_unique<NativeBallWindow>();
  if (!native_ball_->Create(GetHandle(), [this](const std::string& event) {
        if (window_channel_) {
          window_channel_->InvokeMethod(
              "ballEvent",
              std::make_unique<flutter::EncodableValue>(event));
        }
      })) {
    return false;
  }

  native_orbit_ = std::make_unique<NativeOrbitWindow>();
  if (!native_orbit_->Create(GetHandle(), [this](const std::string& event) {
        if (window_channel_) {
          window_channel_->InvokeMethod(
              "ballEvent",
              std::make_unique<flutter::EncodableValue>(event));
        }
      })) {
    return false;
  }
  // Wire the orbit to the main ball so its active opacity stays in sync with
  // the constellation's expand progress.
    native_orbit_->SetBall(native_ball_.get());
  }
#else
  (void)0;  // keep the static analysers quiet about unused callback path
#endif  // JIANHE_USE_NATIVE_BALL

  if (!background_sync_) {
    wake_hot_key_registered_ =
        RegisterHotKey(GetHandle(), kWakeHotKeyId, wake_hot_key_modifiers_,
                       wake_hot_key_virtual_key_) != FALSE;
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->SetPanelVisible(false);
    // Keep the D3D child alive after the first frame. In native-ball mode the
    // host remains alpha=0 outside panel stages, so the child is invisible to
    // the user. Avoiding SW_HIDE keeps ANGLE's swap chain warm and prevents a
    // stale or cleared first frame when a panel opens.
    HWND d3d_view = flutter_controller_->view()->GetNativeWindow();
    if (d3d_view) {
      ShowWindow(d3d_view, SW_SHOWNOACTIVATE);
    }
    if (native_orbit_) {
      native_orbit_->Hide();
    }
    if (native_ball_) {
      native_ball_->Show();
    }
    if (!background_sync_ && !wake_hot_key_registered_ && window_channel_) {
      window_channel_->InvokeMethod(
          "ballEvent", std::make_unique<flutter::EncodableValue>(
                           std::string("hotkeyUnavailable")));
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Keep the panel clip in sync with the ball in real time. The Dart side
  // also reacts to the dock change for its own layout, but it can only
  // update Flutter pixels - the native D3D child clip has to be refreshed
  // from C++ too, otherwise the area outside the panel would briefly show
  // the host's dark background while the user drags the ball with a panel
  // open.
  if (native_ball_) {
    native_ball_->SetDockChangedCallback(
        [this](BallDockEdge) { UpdatePanelRegion(panel_visible()); });
  }

  return true;
}

void FlutterWindow::UpdatePanelRegion(bool panel_visible, bool redraw,
                                      bool update_host, bool update_d3d) {
#if JIANHE_USE_NATIVE_BALL
  if (!flutter_controller_) {
    return;
  }
  HWND d3d_view = flutter_controller_->view()->GetNativeWindow();
  if (!d3d_view) {
    return;
  }
  // When no panel is on screen there is nothing to clip. Clear the regions
  // we installed on the D3D child and the host on the last panel stage so
  // the menu/collapsed host can be a fully transparent rectangle. The next
  // setSize -> UpdatePanelRegion will install a fresh region.
  if (!panel_visible) {
    if (update_d3d) {
      SetWindowRgn(d3d_view, nullptr, redraw ? TRUE : FALSE);
    }
    if (update_host) {
      SetWindowRgn(GetHandle(), nullptr, redraw ? TRUE : FALSE);
    }
    return;
  }
  RECT client;
  GetClientRect(GetHandle(), &client);
  const BallDockEdge ball_edge =
      native_ball_ ? native_ball_->edge() : BallDockEdge::kRight;
  const UINT dpi = GetDpiForWindow(GetHandle());
  const double scale = dpi / 96.0;
  // Match ball_home_page.dart::_buildPaperPanel: 8px window margin, plus
  // ballDiameter (72 logical px) + 4px on the side where the ball is
  // docked. 24px is the panel's ClipRRect radius.
  const int ball_size_px = static_cast<int>(std::round(72.0 * scale));
  const int panel_margin_px = static_cast<int>(std::round(8.0 * scale));
  const int panel_offset_px = static_cast<int>(std::round(4.0 * scale));
  const int panel_radius_px = static_cast<int>(std::round(24.0 * scale));
  int panel_left = 0;
  int panel_top = 0;
  int panel_right = 0;
  int panel_bottom = 0;
  // The region must match _buildPaperPanel's Positioned rect to the pixel.
  // If we leave any pixel out, the D3D child will paint its ANGLE clear
  // colour (opaque black) into that pixel because the Flutter renderer never
  // draws there - the user sees a dark frame around the panel.
  // Positioned contract: left/right/top/bottom are the gaps from the host
  // edges to the panel edges, in logical px. The ball is a 72-px disc plus an
  // 8-px margin, so the gap on the docked side is 72 px (kLeft/kRight) or
  // 72+4 px (kTop reserves the 4 px of panel_offset_px on top, kBottom on
  // the bottom). The cross axis also reserves ball_size_px (72 px) — see _buildPaperPanel in ball_home_page.dart.
  switch (ball_edge) {
    case BallDockEdge::kLeft:
      panel_left = ball_size_px;
      panel_top = panel_margin_px;
      panel_right = client.right - panel_margin_px;
      panel_bottom = client.bottom - ball_size_px;
      break;
    case BallDockEdge::kRight:
      panel_left = panel_margin_px;
      panel_top = panel_margin_px;
      panel_right = client.right - ball_size_px;
      panel_bottom = client.bottom - ball_size_px;
      break;
    case BallDockEdge::kTop:
      panel_left = panel_margin_px;
      panel_top = ball_size_px + panel_offset_px;
      panel_right = client.right - ball_size_px;
      panel_bottom = client.bottom - panel_margin_px;
      break;
    case BallDockEdge::kBottom:
      panel_left = panel_margin_px;
      panel_top = panel_margin_px;
      panel_right = client.right - ball_size_px;
      panel_bottom = client.bottom - ball_size_px;
      break;
  }
  const auto apply_region = [&](HWND window, bool repaint) {
    HRGN region = CreateRoundRectRgn(
        panel_left, panel_top, panel_right, panel_bottom,
        panel_radius_px * 2, panel_radius_px * 2);
    if (region && SetWindowRgn(window, region, repaint ? TRUE : FALSE) == 0) {
      DeleteObject(region);
    }
  };
  // The host region controls the visible paper shape; the D3D child region
  // controls how much Flutter content is exposed inside it. During live
  // expansion these deliberately advance at different times.
  // Prepare the child clip before exposing the matching host area. Applying
  // the host first with redraw enabled lets DWM composite its dark class
  // backing between the two SetWindowRgn calls, which appears as a black edge
  // during an interactive resize. When both regions change, only the final
  // host update requests a redraw.
  if (update_d3d) {
    apply_region(d3d_view, update_host ? false : redraw);
  }
  if (update_host) {
    apply_region(GetHandle(), redraw);
  }
#else
  // Flutter-render mode does not use the native ball, so there is no edge
  // to align the clip to - the panel fills the whole host there.
  if (flutter_controller_) {
    HWND d3d_view = flutter_controller_->view()->GetNativeWindow();
    if (d3d_view) {
      SetWindowRgn(d3d_view, nullptr, TRUE);
    }
  }
#endif  // JIANHE_USE_NATIVE_BALL
}
void FlutterWindow::StartPanelFadeIn() {
  StopPanelFade(false);
  panel_fade_start_ms_ = GetTickCount64();
  SetPanelVisible(true, 0);
  panel_fade_timer_id_ =
      SetTimer(GetHandle(), kPanelFadeTimerId, 16, nullptr);
  if (panel_fade_timer_id_ == 0) {
    SetPanelOpacity(255);
  }
}

void FlutterWindow::StopPanelFade(bool finish_visible) {
  if (panel_fade_timer_id_ != 0 && GetHandle()) {
    KillTimer(GetHandle(), panel_fade_timer_id_);
  }
  panel_fade_timer_id_ = 0;
  if (finish_visible) {
    SetPanelOpacity(255);
  }
}

void FlutterWindow::OnPanelFadeTick() {
  const double elapsed =
      static_cast<double>(GetTickCount64() - panel_fade_start_ms_);
  double progress = elapsed / kPanelFadeDurationMs;
  if (progress < 0.0) progress = 0.0;
  if (progress > 1.0) progress = 1.0;
  const double eased = EaseOutCubic(progress);
  SetPanelOpacity(static_cast<BYTE>(255.0 * eased + 0.5));
  if (progress >= 1.0) {
    StopPanelFade(true);
  }
}

void FlutterWindow::NotifyPanelSizeChanged() {
  if (!window_channel_ || !flutter_controller_ ||
      panel_resize_update_in_flight_) {
    return;
  }
  RECT client{};
  GetClientRect(GetHandle(), &client);
  const UINT dpi = GetDpiForWindow(GetHandle());
  const double scale = (dpi > 0 ? dpi : 96.0) / 96.0;
  const double width = (client.right - client.left) / scale;
  const double height = (client.bottom - client.top) / scale;
  panel_resize_update_in_flight_ = true;
  panel_resize_frame_drawn_ = false;
  panel_resize_dart_acknowledged_ = false;
  in_flight_panel_width_ = width;
  in_flight_panel_height_ = height;
  // Only one resize update can be in flight, so only one engine callback can
  // be registered. An unrelated early frame merely satisfies one half of the
  // barrier; Dart's acknowledgement still has to arrive before completion.
  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    panel_resize_frame_drawn_ = true;
    TryCompletePanelResizeUpdate();
  });
  flutter::EncodableMap arguments;
  arguments[flutter::EncodableValue("width")] = flutter::EncodableValue(width);
  arguments[flutter::EncodableValue("height")] =
      flutter::EncodableValue(height);
  window_channel_->InvokeMethod(
      "panelResized", std::make_unique<flutter::EncodableValue>(arguments));
}

void FlutterWindow::DispatchPendingBackgroundSync() {
  if (!background_sync_pending_ || !background_sync_dart_ready_ ||
      !window_channel_) {
    return;
  }
  background_sync_pending_ = false;
  window_channel_->InvokeMethod("backgroundSyncRequested", nullptr);
}

void FlutterWindow::SchedulePanelSizeChanged() {
  if (panel_resize_timer_id_ != 0 || panel_resize_update_in_flight_ ||
      !GetHandle()) {
    return;
  }
  // A native sizing loop can emit several WM_SIZE messages within one display
  // frame. Coalesce them so Dart rebuilds at most once per frame instead of
  // alternating between multiple stale panel layouts on screen.
  panel_resize_timer_id_ =
      SetTimer(GetHandle(), kPanelResizeTimerId, 16, nullptr);
}

void FlutterWindow::TryCompletePanelResizeUpdate() {
  if (!panel_resize_update_in_flight_ || !panel_resize_frame_drawn_ ||
      !panel_resize_dart_acknowledged_) {
    return;
  }

  RECT client{};
  GetClientRect(GetHandle(), &client);
  const UINT dpi = GetDpiForWindow(GetHandle());
  const double scale = (dpi > 0 ? dpi : 96.0) / 96.0;
  const double current_width = (client.right - client.left) / scale;
  const double current_height = (client.bottom - client.top) / scale;
  const bool current_size_was_drawn =
      std::abs(current_width - in_flight_panel_width_) < 0.5 &&
      std::abs(current_height - in_flight_panel_height_) < 0.5;

  if (panel_visible() && current_size_was_drawn) {
    // The frame is already available. Changing only the D3D clip with redraw
    // disabled avoids re-entering Flutter's paint path from the frame callback.
    UpdatePanelRegion(true, false, false, true);
  }

  panel_resize_update_in_flight_ = false;
  panel_resize_frame_drawn_ = false;
  panel_resize_dart_acknowledged_ = false;
  in_flight_panel_width_ = -1.0;
  in_flight_panel_height_ = -1.0;

  if (panel_visible() && !current_size_was_drawn) {
    // Intermediate sizes are deliberately dropped. Queue only the newest host
    // size after the previous update has fully completed.
    SchedulePanelSizeChanged();
  }
}

void FlutterWindow::SettleCloseRequest() {
  close_request_state_ = CloseRequestState::kSettled;
  if (GetHandle()) {
    KillTimer(GetHandle(), kCloseRequestTimerId);
  }
}

void FlutterWindow::OnCloseRequestReply() {
  // The engine never delivered "closeRequested" to a Dart handler (channel
  // not implemented, engine shutting down). Fall back to the plain close.
  if (close_request_state_ == CloseRequestState::kWaiting) {
    SettleCloseRequest();
    PostMessage(GetHandle(), WM_CLOSE, 0, 0);
  }
}

void FlutterWindow::OnDestroy() {
  StopPanelFade(false);
  if (panel_resize_timer_id_ != 0 && GetHandle()) {
    KillTimer(GetHandle(), panel_resize_timer_id_);
    panel_resize_timer_id_ = 0;
  }
  if (close_request_state_ == CloseRequestState::kWaiting) {
    close_request_state_ = CloseRequestState::kSettled;
  }
  if (GetHandle()) {
    KillTimer(GetHandle(), kCloseRequestTimerId);
  }
  if (wake_hot_key_registered_) {
    UnregisterHotKey(GetHandle(), kWakeHotKeyId);
    wake_hot_key_registered_ = false;
  }
  native_orbit_.reset();
  native_ball_.reset();
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kJianHeActivateExistingInstanceMessage) {
    // The host can be transparent while only the native floating ball is
    // visible, so explicitly raise both windows on a repeated launch.
    SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    if (native_ball_) {
      native_ball_->Show();
    }
    return 1;
  }
  if (message == kJianHeBackgroundSyncMessage) {
    // wparam=1 means the launcher persisted this request first. Keep that
    // marker intact until Dart is ready: if this process crashes during
    // startup, the launcher can then take over instead of mistaking the
    // native window receipt for a completed handoff.
    if (wparam == 0) {
      background_sync_pending_ = true;
    } else if (background_sync_dart_ready_ &&
               ConsumeBackgroundSyncPending()) {
      background_sync_pending_ = true;
    }
    DispatchPendingBackgroundSync();
    return 1;
  }
  if (message == WM_CLOSE) {
    // The host window lives as long as the process, so a close request
    // (X button, Alt+F4, taskbar, or Dart's quit()) must let Dart flush
    // in-memory state - an unsaved editor draft - before teardown. Hold the
    // window open until Dart confirms; the watchdog timer below plus the
    // "closeRequested" reply handler guarantee the window still closes when
    // the engine never answers.
    if (close_request_state_ == CloseRequestState::kSettled) {
      // Dart already confirmed (or the watchdog fired); this WM_CLOSE was
      // posted from the settle path so the destroy runs inside the message
      // loop instead of inside an engine dispatch callback.
      Destroy();
      return 0;
    }
    if (close_request_state_ == CloseRequestState::kWaiting) {
      // Already flushing; ignore repeated close clicks until it finishes.
      return 0;
    }
    if (!window_channel_ || !flutter_controller_) {
      // No engine to flush anything: close exactly as before.
      Destroy();
      return 0;
    }
    close_request_state_ = CloseRequestState::kWaiting;
    SetTimer(GetHandle(), kCloseRequestTimerId, kCloseRequestTimeoutMs,
             nullptr);
    window_channel_->InvokeMethod(
        "closeRequested", nullptr,
        std::make_unique<
            flutter::MethodResultFunctions<flutter::EncodableValue>>(
            [this](const flutter::EncodableValue*) { OnCloseRequestReply(); },
            [this](const std::string&, const std::string&,
                   const flutter::EncodableValue*) { OnCloseRequestReply(); },
            [this]() { OnCloseRequestReply(); }));
    return 0;
  }
  if (message == WM_HOTKEY && wparam == kWakeHotKeyId) {
    if (window_channel_) {
      window_channel_->InvokeMethod(
          "ballEvent", std::make_unique<flutter::EncodableValue>(
                           std::string("hotkey")));
    }
    return 0;
  }
  if (message == WM_TIMER && wparam == kPanelFadeTimerId) {
    OnPanelFadeTick();
    return 0;
  }
  if (message == WM_TIMER && wparam == kPanelResizeTimerId) {
    KillTimer(GetHandle(), kPanelResizeTimerId);
    panel_resize_timer_id_ = 0;
    NotifyPanelSizeChanged();
    return 0;
  }
  if (message == WM_TIMER && wparam == kCloseRequestTimerId) {
    if (close_request_state_ == CloseRequestState::kWaiting) {
      // Dart never answered within the budget (wedged handler or engine);
      // close anyway rather than leaving an unclosable window.
      SettleCloseRequest();
      PostMessage(GetHandle(), WM_CLOSE, 0, 0);
    }
    return 0;
  }

  if (message == WM_ENTERSIZEMOVE) {
    // A modal move/resize loop started (ball drag via HTCAPTION, or a panel
    // edge resize). The pointer may stop being tracked by the Flutter view,
    // so Dart suspends the auto-collapse timer until the loop exits.
    panel_resize_active_ = panel_visible();
    if (window_channel_) {
      window_channel_->InvokeMethod(
          "ballEvent", std::make_unique<flutter::EncodableValue>(
                           std::string("resizeStart")));
    }
    return 0;
  }
  if (message == WM_EXITSIZEMOVE) {
    panel_resize_active_ = false;
    if (panel_resize_timer_id_ != 0 && GetHandle()) {
      KillTimer(GetHandle(), panel_resize_timer_id_);
      panel_resize_timer_id_ = 0;
    }
    // Keep the host at its exact final shape, but leave the D3D child at its
    // last presented region. Dart's final frame acknowledgement exposes it.
    if (panel_visible()) {
      UpdatePanelRegion(true, false, true, false);
      RedrawWindow(GetHandle(), nullptr, nullptr,
                   RDW_INVALIDATE | RDW_ERASE | RDW_NOCHILDREN);
      NotifyPanelSizeChanged();
    }
    if (window_channel_) {
      window_channel_->InvokeMethod(
          "ballEvent", std::make_unique<flutter::EncodableValue>(
                           std::string("resizeEnd")));
    }
    return 0;
  }

  if (message == WM_ERASEBKGND && panel_visible()) {
    // While a panel is visible the host is opaque; if the D3D child ever lags
    // behind the growing host during a user resize, paint the gap in the
    // panel's paper colour instead of the dark class background brush. Handle
    // this before Flutter's top-level proc: it may consume WM_ERASEBKGND and
    // prevent this fallback from running.
    HDC hdc = reinterpret_cast<HDC>(wparam);
    RECT client{};
    GetClientRect(hwnd, &client);
    FillRect(hdc, &client, PaperBrush());
    return 1;
  }

  if (message == WM_PAINT && panel_visible()) {
    // SetWindowRgn can invalidate newly exposed host pixels without first
    // sending WM_ERASEBKGND. Paint those pixels explicitly so the class's
    // dark transparent-key brush can never survive for a compositor frame.
    PAINTSTRUCT paint{};
    HDC hdc = BeginPaint(hwnd, &paint);
    if (hdc) {
      FillRect(hdc, &paint.rcPaint, PaperBrush());
    }
    EndPaint(hwnd, &paint);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {

    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  const LRESULT result =
      Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  if (message == WM_SIZE && panel_visible()) {
    // The base class has already resized the D3D child. Refresh the panel
    // clip (the host/D3D regions are stale after the resize) and tell Dart
    // the new logical size so the Flutter layout follows a user edge resize.
    // Grow the paper-coloured host immediately, but keep the D3D clip on the
    // last confirmed Flutter frame until the matching new frame is ready.
    if (panel_resize_active_) {
      UpdatePanelRegion(true, false, true, false);
      RedrawWindow(GetHandle(), nullptr, nullptr,
                   RDW_INVALIDATE | RDW_ERASE | RDW_NOCHILDREN);
      SchedulePanelSizeChanged();
    } else {
      UpdatePanelRegion(true);
      NotifyPanelSizeChanged();
    }
  }
  if ((message == WM_SIZE || message == WM_MOVE ||
       message == WM_WINDOWPOSCHANGED) &&
      native_ball_) {
    // Whatever raised/moved the host (engine frame processing, DWM, or the
    // dock logic itself), keep the ball on top so it stays clickable.
    native_ball_->Show();
    // The native orbit is what actually shows the menu now, so it must
    // follow the host whenever the host moves or resizes. We only ask the
    // orbit to re-render when it is visible, otherwise the call would
    // do pointless GDI+ work for an invisible window.
    if (native_orbit_ && native_orbit_->is_visible()) {
      const BallDockEdge edge =
          native_ball_ ? native_ball_->edge() : BallDockEdge::kRight;
      native_orbit_->PositionForHost(edge);
    }
  }
  if (message == WM_DPICHANGED && native_ball_) {
    // The base class resized the host for the new DPI; re-dock the ball so it
    // stays flush against the edge on the new monitor scale.
    native_ball_->PositionForHost();
    native_ball_->Show();
  }
  return result;
}
