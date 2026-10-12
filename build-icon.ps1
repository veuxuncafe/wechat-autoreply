param(
  [ValidateSet('bubble','bolt','dark','circle','line')][string]$Style = 'bubble'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$assets = Join-Path $root 'assets'
$ico = Join-Path $assets 'icon.ico'
$exe = Join-Path $root 'wx-panel.exe'
$cs = Join-Path $root 'wx-launcher.cs'
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '微信自动回复控制台.lnk'

Write-Output ("1/4 regenerate the icon (style={0})" -f $Style)
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'make-icon.ps1') -Style $Style -OutIco $ico -Preview (Join-Path $assets 'icon-preview.png') | ForEach-Object { Write-Output ("    " + $_) }

Write-Output '2/4 compile the launcher with the icon embedded'
$manifest = Join-Path $PSScriptRoot 'wx-panel.manifest'
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc)) { $csc = "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
$psDll = [System.Management.Automation.PSObject].Assembly.Location
if (-not (Test-Path -LiteralPath $psDll)) { $psDll = "$env:SystemRoot\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll" }
if (-not (Test-Path -LiteralPath $psDll)) { throw "System.Management.Automation.dll not found - cannot build the hosting launcher" }
if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }
& $csc /nologo /target:winexe "/win32icon:$ico" "/win32manifest:$manifest" "/out:$exe" "/r:$psDll" $cs | ForEach-Object { Write-Output ("    " + $_) }
Write-Output ("    exe {0} bytes" -f (Get-Item -LiteralPath $exe).Length)

Write-Output '3/4 point the desktop shortcut at the exe'
$ws = New-Object -ComObject WScript.Shell
$l = $ws.CreateShortcut($lnk)
$l.TargetPath = $exe
$l.Arguments = ''
$l.WorkingDirectory = $root
$l.IconLocation = "$exe,0"
$l.Description = '微信自动回复控制台'
$l.Save()
Write-Output ("    target = {0}" -f ($ws.CreateShortcut($lnk)).TargetPath)

Write-Output '4/4 refresh the shell icon cache'
Add-Type -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, System.IntPtr a, System.IntPtr b);' -Name Refresh -Namespace DshBuild
[DshBuild.Refresh]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
try { & "$env:SystemRoot\System32\ie4uinit.exe" -show } catch { }
Write-Output ("done - style={0}" -f $Style)
