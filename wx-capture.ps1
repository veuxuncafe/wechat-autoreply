# wx-capture.ps1 - capture the WeChat window (or a layout area) to a PNG for OCR reading.
# READ-ONLY: never clicks, never types, never sends. This is only the CLI wrapper; the
# implementation lives in wx-shot-lib.ps1, which wx-watch.ps1 calls in-process.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File wx-capture.ps1 -Area chatctx
#   powershell ... -File wx-capture.ps1 -Area header -Upscale 3 -AsJson
#
# Areas: window | chat | chatctx | input | list | header | send
# Writes shots\<area>-latest.png plus a timestamped copy and prints file size and sha16.

param(
  [ValidateSet('window', 'chat', 'chatctx', 'input', 'list', 'header', 'send')][string]$Area = 'window',
  [int]$Upscale = 1,
  [switch]$AsJson,
  [ValidateSet('PrintWindow', 'Screen')][string]$Method = 'PrintWindow',
  [switch]$KeepForeground
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'wx-shot-lib.ps1')

$info = Invoke-WxShot -Area $Area -Upscale $Upscale -Method $Method -KeepForeground:$KeepForeground
foreach ($n in $info.Notes) { Write-Output ('note: ' + $n) }
if (-not $info.Ok) { Write-Output ('ERROR: ' + $info.Error); exit $info.ExitCode }

if ($AsJson) { $info | ConvertTo-Json -Depth 3 }
else {
  Write-Output ('area   : ' + $info.Area)
  Write-Output ('method : ' + $info.Method + '  (foregroundOk=' + $info.ForegroundOk + ' blank=' + $info.Blank + ')')
  Write-Output ('file   : ' + $info.File)
  Write-Output ('latest : ' + $info.Latest)
  Write-Output ('size   : ' + $info.Width + 'x' + $info.Height + '  ' + $info.Bytes + ' bytes')
  Write-Output ('sha16  : ' + $info.Sha16)
  if ($info.Blank) { Write-Output 'WARNING: captured frame looks blank - do not trust it.' }
}
