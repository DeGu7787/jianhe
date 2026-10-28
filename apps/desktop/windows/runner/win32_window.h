#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// Dock edges supported by the floating ball window.
enum class BallDockEdge { kLeft, kRight, kTop, kBottom };

// Returns the stable string name used in window-channel events.
const char* BallDockEdgeName(BallDockEdge edge);

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a win32 window with |title| that is positioned and sized using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size this function will scale the inputted width and height as
  // as appropriate for the default monitor. The window is invisible until
  // |Show| is called. Returns true if the window was created successfully.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // Show the current window. Returns true if the window was successfully shown.
  bool Show();

  // Release OS resources associated with window.
  void Destroy();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

  // Shows or hides the Flutter panel. A caller may start a visible panel at
  // alpha 0 and raise it gradually without recreating the D3D surface.
  void SetPanelVisible(bool visible, BYTE initial_opacity = 255);

  // Resizes the window in logical pixels while keeping the floating ball
  // attached to its docked screen edge. Returns the edge the window is docked to.
  BallDockEdge ResizeDocked(unsigned int width, unsigned int height,
                            BallDockEdge edge, double offset);

  // Starts a native window drag and snaps the window to the nearest work-area
  // edge when the pointer is released, reporting the final dock state.
  void DragAndSnap(BallDockEdge* edge_out, double* offset_out);

 protected:
  // Returns true if a real Flutter panel (browser/composer/editor/settings)
  // is currently being shown. Subclasses consult this when they need to
  // react to the host's panel-vs-collapsed state without re-deriving it
  // from the window attributes.
  bool panel_visible() const { return panel_visible_; }

  // Adjusts the global alpha of the layered Flutter host without changing
  // its visibility state or forcing a swap-chain rebuild.
  void SetPanelOpacity(BYTE opacity);

  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Called when Destroy is called.
  virtual void OnDestroy();

 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // Update the window frame's theme to match the system theme.
  static void UpdateTheme(HWND const window);

  bool quit_on_close_ = false;

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // window handle for hosted content.
  HWND child_content_ = nullptr;

  // The native ball/menu owns interaction while the Flutter panel is hidden.
  // Keeping this state lets transparent menu pixels pass clicks to the desktop.
  bool panel_visible_ = false;
};

#endif  // RUNNER_WIN32_WINDOW_H_
