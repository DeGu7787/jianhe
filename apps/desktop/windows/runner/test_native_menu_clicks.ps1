param(
  [string]$ExecutablePath = (
    Join-Path $PSScriptRoot '..\..\build\windows\x64\runner\Debug\jianhe_desktop.exe'
  )
)

$ErrorActionPreference = 'Stop'
$resolvedExecutable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$startedProcess = $null
$appProcess = Get-Process -Name jianhe_desktop -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -eq $resolvedExecutable } |
  Select-Object -First 1

if ($null -eq $appProcess) {
  $startedProcess = Start-Process -FilePath $resolvedExecutable -PassThru
  Start-Sleep -Milliseconds 2500
  $appProcess = Get-Process -Id $startedProcess.Id
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class JianheNativeMenuProbe {
  public delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

  [DllImport("user32.dll")]
  public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

  [DllImport("user32.dll")]
  private static extern bool EnumWindows(
      EnumWindowsCallback callback,
      IntPtr parameter);

  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(
      IntPtr window,
      out uint processId);

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetClassName(
      IntPtr window,
      StringBuilder className,
      int maximumLength);

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr window, out Rect rect);

  [DllImport("user32.dll")]
  public static extern uint GetDpiForWindow(IntPtr window);

  [DllImport("user32.dll")]
  public static extern IntPtr SendMessage(
      IntPtr window,
      uint message,
      IntPtr wParam,
      IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool PostMessage(
      IntPtr window,
      uint message,
      IntPtr wParam,
      IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int x, int y);

  [DllImport("user32.dll")]
  public static extern void mouse_event(
      uint flags,
      uint dx,
      uint dy,
      uint data,
      UIntPtr extraInfo);

  public struct Rect {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }

  public static IntPtr Find(uint processId, string expectedClass) {
    IntPtr result = IntPtr.Zero;
    EnumWindows((window, parameter) => {
      uint candidateProcessId;
      GetWindowThreadProcessId(window, out candidateProcessId);
      if (candidateProcessId != processId) {
        return true;
      }
      var className = new StringBuilder(128);
      GetClassName(window, className, className.Capacity);
      if (className.ToString() == expectedClass) {
        result = window;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return result;
  }

  public static string ZOrder(uint processId) {
    var classes = new List<string>();
    EnumWindows((window, parameter) => {
      uint candidateProcessId;
      GetWindowThreadProcessId(window, out candidateProcessId);
      if (candidateProcessId == processId) {
        var className = new StringBuilder(128);
        GetClassName(window, className, className.Capacity);
        classes.Add(className.ToString());
      }
      return true;
    }, IntPtr.Zero);
    return string.Join(">", classes);
  }

  public static IntPtr MousePosition(int x, int y) {
    return (IntPtr)((y << 16) | (x & 0xffff));
  }
}
'@

# Per-monitor-v2 makes GetWindowRect return the same physical pixels used by
# the native layered windows.
[JianheNativeMenuProbe]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null

$processId = [uint32]$appProcess.Id
$hostWindow = [JianheNativeMenuProbe]::Find(
  $processId,
  'FLUTTER_RUNNER_WIN32_WINDOW'
)
$ballWindow = [JianheNativeMenuProbe]::Find(
  $processId,
  'JIANHE_NATIVE_BALL_WINDOW'
)
$orbitWindow = [JianheNativeMenuProbe]::Find(
  $processId,
  'JIANHE_NATIVE_ORBIT_WINDOW'
)

if ($hostWindow -eq [IntPtr]::Zero -or
    $ballWindow -eq [IntPtr]::Zero -or
    $orbitWindow -eq [IntPtr]::Zero) {
  throw 'Jianhe native windows were not created.'
}

$dpi = [JianheNativeMenuProbe]::GetDpiForWindow($hostWindow)
function Convert-LogicalWidth([int]$width) {
  return [int][Math]::Round($width * $dpi / 96.0)
}

function Get-HostWidth {
  $rect = New-Object JianheNativeMenuProbe+Rect
  [JianheNativeMenuProbe]::GetWindowRect($hostWindow, [ref]$rect) | Out-Null
  return $rect.Right - $rect.Left
}

function Invoke-BallTap {
  # PostMessage is async (SendMessage waits for the window to process), so
  # we don't get blocked when the ball window is busy. The native side
  # needs the full WM_LBUTTONDOWN -> WM_LBUTTONUP sequence to fire the
  # `tap` notification, so we send both messages.
  [JianheNativeMenuProbe]::PostMessage(
    $ballWindow,
    0x0201,
    [IntPtr]::Zero,
    [JianheNativeMenuProbe]::MousePosition(36, 36)
  ) | Out-Null
  Start-Sleep -Milliseconds 30
  [JianheNativeMenuProbe]::PostMessage(
    $ballWindow,
    0x0202,
    [IntPtr]::Zero,
    [JianheNativeMenuProbe]::MousePosition(36, 36)
  ) | Out-Null
  Start-Sleep -Milliseconds 250
}

function Open-Menu {
  $collapsedWidth = Convert-LogicalWidth 88
  if ((Get-HostWidth) -ne $collapsedWidth) {
    Invoke-BallTap
  }
  if ((Get-HostWidth) -eq $collapsedWidth) {
    Invoke-BallTap
  }
  $menuWidth = Convert-LogicalWidth 390
  if ((Get-HostWidth) -ne $menuWidth) {
    throw "Native menu did not open; width was $(Get-HostWidth)."
  }
}

function Invoke-MenuAction(
  [string]$name,
  [int]$index,
  [int]$expectedLogicalWidth
) {
  Open-Menu

  # Compute the screen coordinates of sub-ball [index] using the same
  # corner-aware geometry as native_orbit_window.cpp::SubBallTargetPosition.
  # This way the test does not hard-code coordinates that depend on the
  # corner-detection logic.
  $ballRect = New-Object JianheNativeMenuProbe+Rect
  [JianheNativeMenuProbe]::GetWindowRect($ballWindow, [ref]$ballRect) | Out-Null
  $hostRect = New-Object JianheNativeMenuProbe+Rect
  [JianheNativeMenuProbe]::GetWindowRect($hostWindow, [ref]$hostRect) | Out-Null
  $dpi = [JianheNativeMenuProbe]::GetDpiForWindow($hostWindow)
  $scale = $dpi / 96.0

  # Ball center in host logical pixels.
  $bx = ($ballRect.Left + 36 - $hostRect.Left) * 96.0 / $dpi
  $by = ($ballRect.Top + 36 - $hostRect.Top) * 96.0 / $dpi

  $layout = Get-SubBallLogical $bx $by $index
  $sxPx = $hostRect.Left + $layout.X * $scale
  $syPx = $hostRect.Top + $layout.Y * $scale
  $sx = [int][Math]::Round($sxPx)
  $sy = [int][Math]::Round($syPx)
  Write-Host ("    sub-ball[{0}] host-logical=({1:N1},{2:N1}) screen=({3},{4}) corner={5}" -f $index, $layout.X, $layout.Y, $sx, $sy, $layout.Corner)

  # Real pointer events -- SetCursorPos + mouse_event is the most reliable
  # way to drive a layered window that hit-tests against its own bitmap.
  [JianheNativeMenuProbe]::SetCursorPos($sx, $sy) | Out-Null
  Start-Sleep -Milliseconds 30
  [JianheNativeMenuProbe]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) | Out-Null  # LEFTDOWN
  Start-Sleep -Milliseconds 30
  [JianheNativeMenuProbe]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) | Out-Null  # LEFTUP
  Start-Sleep -Milliseconds 500

  $expectedWidth = Convert-LogicalWidth $expectedLogicalWidth
  $actualWidth = Get-HostWidth
  return [pscustomobject]@{
    Action = $name
    ExpectedWidth = $expectedWidth
    ActualWidth = $actualWidth
    Passed = $actualWidth -eq $expectedWidth
  }
}

# Mirrors native_orbit_window.cpp::SubBallTargetPosition so the test can
# compute the screen coordinates of each sub-ball without depending on a
# debug channel.
function Get-SubBallLogical([double]$bx, [double]$by, [int]$index) {
  $kOrbitRadius = 130.0
  $kArcHalfSpan = 5.0 * [Math]::PI / 12.0   # 75 deg
  $kOuter = 100.0
  $kInner = 60.0
  $kCornerHalfSpan = 30.0 * [Math]::PI / 180.0
  $kCornerThreshold = 130.0
  $hostW = 390.0
  $hostH = 360.0

  $dTL = [Math]::Sqrt($bx * $bx + $by * $by)
  $dTR = [Math]::Sqrt(($hostW - $bx) * ($hostW - $bx) + $by * $by)
  $dBL = [Math]::Sqrt($bx * $bx + ($hostH - $by) * ($hostH - $by))
  $dBR = [Math]::Sqrt(($hostW - $bx) * ($hostW - $bx) + ($hostH - $by) * ($hostH - $by))
  $minD = [Math]::Min([Math]::Min($dTL, $dTR), [Math]::Min($dBL, $dBR))
  $corner = $minD -lt $kCornerThreshold

  # Default right-edge center angle; tests run with the ball in the default
  # right-edge dock so this is sufficient.
  $center = [Math]::PI
  if ($corner) {
    $center = [Math]::Atan2($hostH / 2.0 - $by, $hostW / 2.0 - $bx)
  }

  if ($corner) {
    $half = $kCornerHalfSpan
    $angle = $center - $half + 2.0 * $half * ($index / 5.0)
    $r = if (($index % 2) -eq 0) { $kOuter } else { $kInner }
  } else {
    $half = $kArcHalfSpan
    $angle = $center - $half + 2.0 * $half * ($index / 5.0)
    $r = $kOrbitRadius
  }
  $sx = $bx + $r * [Math]::Cos($angle)
  $sy = $by + $r * [Math]::Sin($angle)
  return [pscustomobject]@{ X = $sx; Y = $sy; Corner = $corner; Center = $center }
}

try {
  Open-Menu
  $zOrder = [JianheNativeMenuProbe]::ZOrder($processId)
  $requiredPrefix =
    'JIANHE_NATIVE_BALL_WINDOW>' +
    'JIANHE_NATIVE_ORBIT_WINDOW>' +
    'FLUTTER_RUNNER_WIN32_WINDOW'
  if (-not $zOrder.StartsWith($requiredPrefix)) {
    throw "Incorrect native window order: $zOrder"
  }
  $orbitRect = New-Object JianheNativeMenuProbe+Rect
  [JianheNativeMenuProbe]::GetWindowRect($orbitWindow, [ref]$orbitRect) | Out-Null
  $transparentHit = [JianheNativeMenuProbe]::SendMessage(
    $orbitWindow,
    0x0084,
    [IntPtr]::Zero,
    [JianheNativeMenuProbe]::MousePosition($orbitRect.Left + 24, $orbitRect.Top + 180)
  ).ToInt64()
  if ($transparentHit -ne -1) {
    throw "Transparent menu background intercepted pointer input: $transparentHit"
  }
  Invoke-BallTap

  $results = @(
    (Invoke-MenuAction 'Compose' 0 520),
    (Invoke-MenuAction 'Prompt' 1 440),
    (Invoke-MenuAction 'Skills' 2 440),
    (Invoke-MenuAction 'Snippets' 3 440),
    (Invoke-MenuAction 'Create' 4 470),
    (Invoke-MenuAction 'More' 5 450)
  )
  $results | Format-Table -AutoSize
  if ($results.Passed -contains $false) {
    throw 'At least one native menu action opened the wrong stage.'
  }
  Write-Host 'Jianhe native menu regression passed.'
} finally {
  if ((Get-HostWidth) -ne (Convert-LogicalWidth 88)) {
    Invoke-BallTap
  }
  if ($null -ne $startedProcess) {
    Stop-Process -Id $startedProcess.Id -Force -ErrorAction SilentlyContinue
  }
}
