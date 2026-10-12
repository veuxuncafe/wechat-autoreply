# Brings the Windows taskbar back if its window got hidden (a shell glitch).
# Safe to run any time: it only calls ShowWindow on the taskbar window.
$ErrorActionPreference = 'Stop'

Add-Type -Namespace TrayFix -Name N -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr FindWindow(string cls, string win);
'@

$SW_SHOW = 5
$SW_RESTORE = 9
$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002
$SWP_SHOWWINDOW = 0x0040

$found = $false
foreach ($cls in @('Shell_TrayWnd', 'Shell_SecondaryTrayWnd')) {
  $h = [TrayFix.N]::FindWindow($cls, $null)
  if ($h -eq [IntPtr]::Zero) { Write-Host ("{0}: window not found" -f $cls); continue }
  $found = $true
  $was = [TrayFix.N]::IsWindowVisible($h)
  [void][TrayFix.N]::ShowWindow($h, $SW_SHOW)
  [void][TrayFix.N]::ShowWindow($h, $SW_RESTORE)
  [void][TrayFix.N]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW))
  Start-Sleep -Milliseconds 300
  Write-Host ("{0}: visible {1} -> {2}" -f $cls, $was, [TrayFix.N]::IsWindowVisible($h))
}
if (-not $found) {
  Write-Host 'No taskbar window at all - Explorer looks broken. Restarting Explorer is the next step.'
  exit 1
}
