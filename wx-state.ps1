#requires -version 5.1
<#
  wx-state.ps1 - inspect / query the auto-reply state.

    powershell -NoProfile -ExecutionPolicy Bypass -File wx-state.ps1
        -> one-line status: mode, how many inbound handled, last send time, gates

    powershell ... -File wx-state.ps1 -CheckInbound "大雨爽炸了"
        -> prints NEW or SEEN (exit 3 when SEEN), so a watcher can skip re-replying
#>
param(
  [string]$CheckInbound,
  [switch]$Show
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'wx-core.ps1')

$mode = Get-WxMode

if ($CheckInbound) {
  if (Test-WxInboundSeen -Text $CheckInbound) {
    Write-Output ('SEEN: ' + $CheckInbound)
    exit 3
  }
  Write-Output ('NEW: ' + $CheckInbound)
  exit 0
}

$s = Get-WxState
$gate = Test-WxSendAllowed
$sends = @($s.sends)
$last = ''
if ($sends.Count -gt 0) { $last = [string]$sends[-1] }
$inb = @($s.inbound)

Write-Output ('mode        : ' + $mode)
Write-Output ('inbound seen: ' + $inb.Count)
Write-Output ('sends       : ' + $sends.Count + '  last=' + $last)
Write-Output ('next send ok: ' + $gate.Ok + '  (' + $gate.Reason + ')')
if ($inb.Count -gt 0) {
  Write-Output '--- last 5 inbound ---'
  $tail = $inb | Select-Object -Last 5
  foreach ($e in $tail) { Write-Output ('  ' + $e.ts + '  ' + $e.text) }
}
