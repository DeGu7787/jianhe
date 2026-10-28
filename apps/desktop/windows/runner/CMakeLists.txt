cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "background_sync_handoff.cpp"
  "background_sync_task_scheduler.cpp"
  "flutter_window.cpp"
  "installer_language_handoff.cpp"
  "main.cpp"
  "native_ball_window.cpp"
  "native_orbit_window.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Sources are UTF-8 without BOM and contain Chinese text; without /utf-8 MSVC
# reads them as the system codepage (936) and C4819 trips the /WX flag.
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Render-path toggle. 1 = native GDI+ ball/orbit windows (the production path
# for the Windows desktop build), 0 = in-Flutter arc menu (used by the Web
# dev build). The flag is injected at compile time so the layered-window
# alpha logic in win32_window.cpp, the ball/orbit creation in
# flutter_window.cpp, and the initial host size in main.cpp all see the
# same value. Override with `-DJIANHE_USE_NATIVE_BALL=0` to switch paths
# without touching the source.
option(JIANHE_USE_NATIVE_BALL
  "Use the native GDI+ floating ball and orbit windows" ON)
target_compile_definitions(${BINARY_NAME} PRIVATE
  "JIANHE_USE_NATIVE_BALL=$<BOOL:${JIANHE_USE_NATIVE_BALL}>")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "gdiplus.lib" "comctl32.lib" "shell32.lib" "taskschd.lib" "oleaut32.lib" "advapi32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# This is a local-development convenience only. Public releases must be signed
# by the release pipeline with the official Windows publishing certificate.
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND powershell.exe
    -NoLogo
    -NoProfile
    -NonInteractive
    -File "${CMAKE_CURRENT_SOURCE_DIR}/sign_dev_build.ps1"
    -ExecutablePath "$<TARGET_FILE:${BINARY_NAME}>"
    -Configuration "$<CONFIG>"
  VERBATIM
)
