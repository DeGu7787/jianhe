#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "background_sync_handoff.h"
#include "background_sync_task_scheduler.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kJianHeForegroundInstanceMutex[] =
    L"Local\\JianHeDesktop-DAA27BA4-A41E-4F82-9935-9F137FFA5469";
constexpr wchar_t kJianHeBackgroundSyncMutex[] =
    L"Local\\JianHeDesktopBackgroundSync-DAA27BA4-A41E-4F82-9935-"
    L"9F137FFA5469";
constexpr wchar_t kHostWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kHostWindowTitle[] = L"笺盒";
constexpr wchar_t kBackgroundSyncWindowTitle[] = L"笺盒后台同步";
constexpr DWORD kForegroundStartupPollMs = 100;

enum class BackgroundDeliveryResult { kDelivered, kNoForeground };

bool ForegroundInstanceExists() {
  const HANDLE mutex =
      OpenMutexW(SYNCHRONIZE, FALSE, kJianHeForegroundInstanceMutex);
  if (!mutex) return false;
  CloseHandle(mutex);
  return true;
}

bool ActivateExistingInstance() {
  const HWND existing = FindWindowW(kHostWindowClass, kHostWindowTitle);
  if (!existing) return false;
  DWORD_PTR handled = 0;
  return SendMessageTimeoutW(
             existing, kJianHeActivateExistingInstanceMessage, 0, 0,
             SMTO_ABORTIFHUNG | SMTO_BLOCK | SMTO_ERRORONEXIT, 5000,
             &handled) != 0 &&
         handled == 1;
}

BackgroundDeliveryResult DeliverBackgroundSyncToForeground() {
  if (!ForegroundInstanceExists()) {
    return BackgroundDeliveryResult::kNoForeground;
  }

  // Persist before notifying the window. A slow foreground startup can then
  // consume the request from its Dart-ready handshake even when no HWND exists
  // yet, and a crashed startup leaves the marker for the next launch.
  if (MarkBackgroundSyncPending()) {
    HWND notified_window = nullptr;
    while (ForegroundInstanceExists()) {
      const HWND existing = FindWindowW(kHostWindowClass, kHostWindowTitle);
      if (existing && existing != notified_window &&
          PostMessageW(existing, kJianHeBackgroundSyncMessage, 1, 0)) {
        notified_window = existing;
      }
      // The durable marker is removed only after the foreground Dart event
      // listener is ready. Until then this process remains available to take
      // over if the foreground exits during startup.
      if (!IsBackgroundSyncPending()) {
        return BackgroundDeliveryResult::kDelivered;
      }
      Sleep(kForegroundStartupPollMs);
    }
    ClearBackgroundSyncPending();
    return BackgroundDeliveryResult::kNoForeground;
  }

  // Registry access should normally be available for the interactive user.
  // If it is not, keep this lightweight launcher alive until the foreground
  // creates its window or exits. There is deliberately no early timeout whose
  // exit code Task Scheduler would silently ignore.
  while (ForegroundInstanceExists()) {
    const HWND existing = FindWindowW(kHostWindowClass, kHostWindowTitle);
    if (existing &&
        PostMessageW(existing, kJianHeBackgroundSyncMessage, 0, 0)) {
      return BackgroundDeliveryResult::kDelivered;
    }
    Sleep(kForegroundStartupPollMs);
  }
  return BackgroundDeliveryResult::kNoForeground;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool background_sync =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--sync-once") != command_line_arguments.end();
  const bool unregister_background_sync =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--unregister-background-sync") !=
      command_line_arguments.end();

  if (unregister_background_sync) {
    const HRESULT com_result =
        ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    std::wstring error;
    const bool cancelled = CancelBackgroundSyncTask(&error);
    if (SUCCEEDED(com_result)) ::CoUninitialize();
    return cancelled ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  // Prefer the already-running foreground app. It owns the live sync
  // controller and can perform the scheduled cycle without starting a
  // second Flutter engine or opening the database again.
  if (background_sync) {
    const auto delivery = DeliverBackgroundSyncToForeground();
    if (delivery == BackgroundDeliveryResult::kDelivered) return EXIT_SUCCESS;
  }

  // Foreground and scheduled background work have separate lifetimes. A
  // background retry must never prevent the user from opening the app, while
  // each role still remains single-instance within the Windows logon session.
  const wchar_t* instance_mutex_name =
      background_sync ? kJianHeBackgroundSyncMutex
                      : kJianHeForegroundInstanceMutex;
  const HANDLE instance_mutex =
      CreateMutexW(nullptr, FALSE, instance_mutex_name);
  if (!instance_mutex) {
    return EXIT_FAILURE;
  }
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    const bool delivered = background_sync || ActivateExistingInstance();
    CloseHandle(instance_mutex);
    return delivered ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  // Close the startup race where the foreground window appeared after the
  // first lookup but before this process acquired the background mutex.
  if (background_sync) {
    const auto delivery = DeliverBackgroundSyncToForeground();
    if (delivery == BackgroundDeliveryResult::kDelivered) {
      CloseHandle(instance_mutex);
      return EXIT_SUCCESS;
    }
  }

  if (background_sync) {
    // No foreground owns the request now; this standalone process does.
    ClearBackgroundSyncPending();
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, background_sync);
  // Pick the initial host size based on the render path. In native-ball
  // mode the host is fully transparent and the GDI+ orbit/ball windows
  // paint the real UI, so 88x88 is enough to back the corner-anchored
  // floating ball. In Flutter-render mode the host itself has to be
  // menu-sized from the very first frame so the in-Flutter arc menu and
  // paper panel can lay themselves out without a visible resize flicker.
  // The flag is injected by CMake target_compile_definitions so the same
  // value is visible to win32_window.cpp and flutter_window.cpp.
#if JIANHE_USE_NATIVE_BALL
  constexpr unsigned int kHostWidth = 88;
  constexpr unsigned int kHostHeight = 88;
#else
  constexpr unsigned int kHostWidth = 520;
  constexpr unsigned int kHostHeight = 640;
#endif  // JIANHE_USE_NATIVE_BALL
  Win32Window::Point origin(12, 12);
  Win32Window::Size size(kHostWidth, kHostHeight);
  const wchar_t* window_title =
      background_sync ? kBackgroundSyncWindowTitle : kHostWindowTitle;
  if (!window.Create(window_title, origin, size)) {
    CloseHandle(instance_mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  CloseHandle(instance_mutex);
  return static_cast<int>(msg.wParam);
}
