# build-installer.ps1 -- packages the app into one self-contained installer exe.
#
#   payload.zip = the program files (never state\ logs\ shots\, so upgrading keeps user data)
#   the zip is embedded as the resource "payload.zip" and installer.cs unpacks it
#
# The result is copied to the app folder as 微信自动回复-安装.exe; that exe also copies
# itself to <app>\卸载.exe and points the "apps and features" entry at it.
param(
  [string]$App = 'C:\WeChatAutoReply',
  [string]$Work = $PSScriptRoot,
  [string]$OutName = '微信自动回复-安装.exe'
)
$ErrorActionPreference = 'Stop'
$src = Join-Path $Work 'installer.cs'
$manifest = Join-Path $Work 'installer.manifest'
$ico = Join-Path $App 'assets\icon.ico'

# csc only reads UTF-8 when the BOM is there, and installer.cs is full of Chinese literals
$bytes = [System.IO.File]::ReadAllBytes($src)
if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
  [System.IO.File]::WriteAllBytes($src, ([byte[]](0xEF, 0xBB, 0xBF) + $bytes))
  Write-Output 'installer.cs: UTF-8 BOM added (csc needs it for the Chinese literals)'
}

# ---- 1/3 payload ----------------------------------------------------------
$payload = @(
  'wx-core.ps1', 'wx-watch.ps1', 'wx-watch-daemon.ps1', 'wx-panel.ps1',
  'wx-uia.ps1', 'wx-ocr-lib.ps1', 'wx-send.ps1', 'wx-record.ps1',
  'wx-capture.ps1', 'wx-shot-lib.ps1', 'wx-contacts.ps1',
  'winio.ps1', 'winenum.ps1', 'app-tools.ps1',
  'wx-launcher.cs', 'build-icon.ps1', 'make-icon.ps1',
  'wx-panel.exe', 'wx-panel.manifest',
  'prompt-examples\reply-template.txt', 'prompt-examples\proactive-template.txt',
  '打开控制台.cmd', '修复任务栏.cmd', '开机自启-开.cmd', '开机自启-关.cmd',
  'assets\icon.ico', 'assets\icon-preview.png'
)
$zip = Join-Path $Work 'payload.zip'
$stage = Join-Path $Work 'payload-stage'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
[void][System.IO.Directory]::CreateDirectory($stage)
$added = 0
$missing = New-Object System.Collections.Generic.List[string]
foreach ($rel in $payload) {
  $full = Join-Path $App $rel
  if (-not (Test-Path -LiteralPath $full)) { $missing.Add($rel); continue }
  $dest = Join-Path $stage $rel
  $destDir = Split-Path -Parent $dest
  if (-not [System.IO.Directory]::Exists($destDir)) { [void][System.IO.Directory]::CreateDirectory($destDir) }
  Copy-Item -LiteralPath $full -Destination $dest -Force
  $added++
}
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal -Force
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Output ("1/3 payload: {0} files, {1:N0} bytes -> {2}" -f $added, (Get-Item -LiteralPath $zip).Length, $zip)
if ($missing.Count -gt 0) { Write-Output ("    missing (skipped): " + ($missing -join ', ')) }

# ---- 2/3 compile ----------------------------------------------------------
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc)) { $csc = "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path -LiteralPath $csc)) { throw 'csc.exe not found' }
$comp = "$env:SystemRoot\Microsoft.NET\assembly\GAC_MSIL\System.IO.Compression\v4.0_4.0.0.0__b77a5c561934e089\System.IO.Compression.dll"
if (-not (Test-Path -LiteralPath $comp)) { throw ("System.IO.Compression.dll not found: " + $comp) }
$out = Join-Path $Work $OutName
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
Write-Output '2/3 compiling the installer (winexe, admin manifest, icon, payload embedded)'
& $csc /nologo /target:winexe "/win32icon:$ico" "/win32manifest:$manifest" "/out:$out" `
  /r:System.Windows.Forms.dll /r:System.Drawing.dll "/r:$comp" `
  "/resource:$zip,payload.zip" $src | ForEach-Object { Write-Output ('    ' + $_) }
if (-not (Test-Path -LiteralPath $out)) { throw 'compile failed - no exe produced' }
Write-Output ("    {0} bytes" -f (Get-Item -LiteralPath $out).Length)

# ---- 3/3 ship it next to the app -----------------------------------------
Copy-Item -LiteralPath $out -Destination (Join-Path $App $OutName) -Force
Copy-Item -LiteralPath $src -Destination (Join-Path $App 'installer.cs') -Force
Copy-Item -LiteralPath $manifest -Destination (Join-Path $App 'installer.manifest') -Force
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $App 'build-installer.ps1') -Force
Write-Output ("3/3 copied to {0}" -f (Join-Path $App $OutName))
Write-Output 'done'
