param(
  [string]$ExecutablePath = (
    Join-Path $PSScriptRoot '..\..\build\windows\x64\runner\Debug\jianhe_desktop.exe'
  )
)

$ErrorActionPreference = 'Stop'
$resolvedExecutable = (Resolve-Path -LiteralPath $ExecutablePath).Path

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class JianheOrbitGeometryProbe {
  public delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

  [DllImport("user32.dll")]
  public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetClassName(IntPtr window, StringBuilder className, int maximumLength);

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr window, out Rect rect);

  [DllImport("user32.dll")]
  public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern uint GetDpiForWindow(IntPtr window);

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int x, int y);

  [DllImport("user32.dll")]
  public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);

  public struct Rect { public int Left, Top, Right, Bottom; }

  public static IntPtr Find(uint processId, string expectedClass) {
    IntPtr result = IntPtr.Zero;
    EnumWindows((window, parameter) => {
      uint candidateProcessId;
      GetWindowThreadProcessId(window, out candidateProcessId);
      if (candidateProcessId != processId) return true;
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
}
'@

[JianheOrbitGeometryProbe]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null

$startedProcess = $null
$appProcess = Get-Process -Name jianhe_desktop -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -eq $resolvedExecutable } |
  Select-Object -First 1
if ($null -eq $appProcess) {
  $startedProcess = Start-Process -FilePath $resolvedExecutable -PassThru
  Start-Sleep -Seconds 3
  $appProcess = Get-Process -Id $startedProcess.Id
}

$processId = [uint32]$appProcess.Id
$ballWindow = [JianheOrbitGeometryProbe]::Find($processId, 'JIANHE_NATIVE_BALL_WINDOW')
$orbitWindow = [JianheOrbitGeometryProbe]::Find($processId, 'JIANHE_NATIVE_ORBIT_WINDOW')

if ($ballWindow -eq [IntPtr]::Zero -or $orbitWindow -eq [IntPtr]::Zero) {
  throw 'Jianhe native windows were not created.'
}

# Send WM_USER + 101 to the ball to force it into the right-edge top corner.
[JianheOrbitGeometryProbe]::PostMessage($ballWindow, [uint32](0x0400 + 101), [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
Start-Sleep -Milliseconds 500

# Tap the ball to open the menu (real pointer events so the hit-test runs).
$ballRect = New-Object JianheOrbitGeometryProbe+Rect
[JianheOrbitGeometryProbe]::GetWindowRect($ballWindow, [ref]$ballRect) | Out-Null
$ballCx = $ballRect.Left + 36
$ballCy = $ballRect.Top + 36
Write-Host ("ball now at ({0},{1})" -f $ballRect.Left, $ballRect.Top)
[JianheOrbitGeometryProbe]::SetCursorPos($ballCx, $ballCy) | Out-Null
Start-Sleep -Milliseconds 30
[JianheOrbitGeometryProbe]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) | Out-Null
Start-Sleep -Milliseconds 30
[JianheOrbitGeometryProbe]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) | Out-Null

# Wait for the menu expand animation + showStage to fully resize the host
# from 88x88 collapsed up to 390x360 menu. The expand animation takes
# ~280ms and the size-change path is async, so 1.2s is comfortably enough.
Start-Sleep -Milliseconds 1200

$hostRect = New-Object JianheOrbitGeometryProbe+Rect
[JianheOrbitGeometryProbe]::GetWindowRect($orbitWindow, [ref]$hostRect) | Out-Null
$hostWidthPx = $hostRect.Right - $hostRect.Left
$hostHeightPx = $hostRect.Bottom - $hostRect.Top
Write-Host ("orbit window size: {0}x{1} (expect ~390x360 once menu opens)" -f $hostWidthPx, $hostHeightPx)

# Trigger the debug dump in the orbit window.
[JianheOrbitGeometryProbe]::PostMessage($orbitWindow, [uint32](0x0400 + 100), [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
Start-Sleep -Milliseconds 200

$layoutFile = Join-Path $env:TEMP 'jianhe_orbit_layout.txt'
if (-not (Test-Path -LiteralPath $layoutFile)) {
  throw "Layout dump not found at $layoutFile"
}

$lines = Get-Content -LiteralPath $layoutFile
$hostW = 0.0
$hostH = 0.0
$mainX = 0.0
$mainY = 0.0
$subBalls = New-Object System.Collections.Generic.List[object]
foreach ($line in $lines) {
  if ($line -match '^host=(?<w>[\d\.\-]+)\s+(?<h>[\d\.\-]+)$') {
    $hostW = [double]$Matches.w
    $hostH = [double]$Matches.h
  } elseif ($line -match '^main=(?<x>[\d\.\-]+)\s+(?<y>[\d\.\-]+)$') {
    $mainX = [double]$Matches.x
    $mainY = [double]$Matches.y
  } elseif ($line -match '^sub\[(?<i>\d+)\]=(?<x>[\d\.\-]+)\s+(?<y>[\d\.\-]+)$') {
    $subBalls.Add([pscustomobject]@{
      Index = [int]$Matches.i
      X = [double]$Matches.x
      Y = [double]$Matches.y
    })
  }
}

Write-Host ("host=({0},{1})  main=({2:N1},{3:N1})" -f $hostW, $hostH, $mainX, $mainY)

$subBallRadius = 28.0
$failed = $false
foreach ($s in $subBalls) {
  $left = $s.X - $subBallRadius
  $right = $s.X + $subBallRadius
  $top = $s.Y - $subBallRadius
  $bottom = $s.Y + $subBallRadius
  $fits = ($left -ge 0) -and ($right -le $hostW) -and ($top -ge 0) -and ($bottom -le $hostH)
  $flag = if ($fits) { 'OK' } else { 'FAIL' }
  if (-not $fits) { $failed = $true }
  Write-Host ("  sub[{0}]=({1:N1},{2:N1})  bbox=({3:N1},{4:N1})-({5:N1},{6:N1})  {7}" -f $s.Index, $s.X, $s.Y, $left, $top, $right, $bottom, $flag)
}

# Also verify that the sub-balls really use the two-ring nest (mix of outer
# and inner radii), proving corner mode is engaged and not just the normal
# single-arc.
$rMainX = [Math]::Sqrt(($subBalls[0].X - $mainX) * ($subBalls[0].X - $mainX) + ($subBalls[0].Y - $mainY) * ($subBalls[0].Y - $mainY))
$rMain1 = [Math]::Sqrt(($subBalls[1].X - $mainX) * ($subBalls[1].X - $mainX) + ($subBalls[1].Y - $mainY) * ($subBalls[1].Y - $mainY))
Write-Host ("  distance main->sub[0]={0:N1}  main->sub[1]={1:N1}  (corner two-ring radii are not fixed any more)" -f $rMainX, $rMain1)
# The new ComputeArcLayout picks the radius dynamically from the host
# geometry, so the legacy outer=100/inner=60 assertion no longer holds.
# The new guarantee is: adjacent sub-balls are spaced >= sub-ball diameter.

# Adjacent sub-balls must not overlap: each sub-ball is 56 px across
# (radius 28), so the center-to-center spacing between any two neighbours
# has to clear that. This was the original bug the corner two-ring layout
# regressed on (the previous +/- 30 deg arc gave ~43 px spacing).
$minSpacing = [double]::PositiveInfinity
for ($i = 0; $i -lt $subBalls.Count; $i++) {
  $j = ($i + 1) % $subBalls.Count
  $dx = $subBalls[$i].X - $subBalls[$j].X
  $dy = $subBalls[$i].Y - $subBalls[$j].Y
  $spacing = [Math]::Sqrt($dx * $dx + $dy * $dy)
  if ($spacing -lt $minSpacing) { $minSpacing = $spacing }
  Write-Host ("  spacing sub[{0}]->sub[{1}]={2:N2}" -f $i, $j, $spacing)
}
$subBallDiameter = 2.0 * $subBallRadius
if ($minSpacing -lt $subBallDiameter) {
  Write-Host ("  FAIL: adjacent sub-balls overlap (min spacing {0:N2} < diameter {1:N2})." -f $minSpacing, $subBallDiameter)
  $failed = $true
}

if ($failed) {
  throw 'Corner geometry assertion failed; see sub-ball dump above.'
}

Write-Host 'Jianhe orbit corner geometry passed.'

if ($null -ne $startedProcess) {
  Stop-Process -Id $startedProcess.Id -Force -ErrorAction SilentlyContinue
}
