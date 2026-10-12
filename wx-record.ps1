#requires -version 5.1
<#
  wx-record.ps1 - records one auto-reply decision, and is the ONLY place that can
  actually send a WeChat message. Policy is enforced here, not by the caller:

    state\mode.txt  = "dryrun" (default) or "live"
      dryrun : the draft is written to logs\drafts.txt and NOTHING is typed into WeChat
      live   : the draft is typed into the open chat and sent

  So even if the model running the watcher decides to send, the script refuses while
  the mode file says dryrun. Flipping that file is the user's switch.

  Examples:
    powershell -NoProfile -ExecutionPolicy Bypass -File wx-record.ps1 `
      -Inbound "大雨爽炸了" -Draft "是啊 今年这雨是真大"

    # dedupe check only (exit 3 when already handled):
    powershell ... -File wx-state.ps1 -CheckInbound "大雨爽炸了"
#>
param(
  [string]$Inbound,
  [string]$Draft,
  [switch]$TrySend,
  # The watcher passes Chinese text through this UTF-8 JSON file instead of the command
  # line, so nothing depends on the console code page.
  [string]$FromJson,
  # Frame hash this decision came from: re-processing one frame must never send twice.
  [string]$FrameSha,
  # A deferred draft being retried: the inbound is already recorded as handled, so the
  # duplicate gate must not swallow the retry. Everything else (mode, rate limits) still applies.
  [switch]$Retry,
  # Conversation this draft belongs to: the send is refused when another chat is open.
  [string]$ExpectTitle = '',
  # The owner's fixed "he sent a wall of text again" line: it has to go out every time and at once,
  # so neither the handled-inbound bookkeeping nor the duplicate/throttle gates may swallow it.
  [switch]$Instant
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'wx-core.ps1')

# If an editor rewrote wx-core.ps1 without its UTF-8 BOM, PowerShell 5.1 decodes the whole file as
# GBK, it fails to parse, and every function it defines is missing. That used to surface as an
# ordinary-looking "DRAFT (mode=, not sent)" and silently ate real replies. Fail loudly instead.
if ((-not (Get-Command Send-WxText -ErrorAction SilentlyContinue)) -or (-not (Get-Command Get-WxMode -ErrorAction SilentlyContinue))) {
  Write-Output 'ERROR: wx-core.ps1 did not load (its functions are missing) - nothing was sent or recorded.'
  exit 4
}

if ($FromJson) {
  $j = Get-Content -LiteralPath $FromJson -Raw -Encoding UTF8 | ConvertFrom-Json
  $Inbound = [string]$j.inbound
  $Draft = [string]$j.draft
  if ($j.frameSha) { $FrameSha = [string]$j.frameSha }
  if ($j.title) { $ExpectTitle = [string]$j.title }
}
if ([string]::IsNullOrWhiteSpace($Inbound) -or [string]::IsNullOrWhiteSpace($Draft)) {
  Write-Output 'ERROR: both an inbound text and a draft are required.'
  exit 2
}

$mode = Get-WxMode
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

if ((-not $Retry) -and (-not $Instant) -and (Test-WxInboundSeen -Text $Inbound -FrameSha $FrameSha)) {
  Write-Output ('SEEN - already handled, nothing recorded: ' + $Inbound)
  exit 3
}

$sendable = ($TrySend -and $mode -eq 'live')
$sent = $false

if ($sendable) {
  $sent = [bool](Send-WxText -Text $Draft -Commit -ExpectTitle $ExpectTitle -AllowRepeat:$Instant)
  if (-not $sent) {
    if ($Instant) {
      if ($Retry) {
        # The watcher still holds this queue entry and has already counted the try: leave it there.
        Add-WxLog 'MISS' ('the queued line did not go out on this retry: "' + $Draft + '"') | Out-Null
      } else {
        # The joke only works right after the paste, so it is queued with a short expiry: the
        # watcher retries it every round for three minutes and then drops it.
        Add-WxPending -Inbound $Inbound -Draft $Draft -Instant
        Add-WxLog 'DEFER' ('the instant line did not go out - queued for a quick retry: "' + $Draft + '"') | Out-Null
      }
    } else {
      # never lose a reply silently: queue it so the watcher retries on a later round
      Add-WxPending -Inbound $Inbound -Draft $Draft
      Add-WxLog 'DEFER' ('send failed, queued for retry: "' + $Draft + '"') | Out-Null
    }
  } elseif ($Retry) {
    Remove-WxPending -Draft $Draft
  }
} else {
  Add-WxLog 'DRYRUN' ('inbound="' + $Inbound + '" draft="' + $Draft + '"') | Out-Null
}

# the inbound is recorded as handled either way (it was handled: a draft exists), while a
# failed send keeps its draft in state\pending.json so the watcher still delivers it later
Add-WxInbound -Text $Inbound -FrameSha $FrameSha

$line = '{0} | {1} | {2} | 收到: {3} | 草稿: {4}' -f $stamp, $mode, $(if ($sent) { 'SENT' } else { 'DRAFT' }), $Inbound, $Draft
Add-Content -LiteralPath (Join-Path $script:WxRoot 'logs\drafts.txt') -Value $line -Encoding UTF8

if ($sent) {
  Write-Output ('SENT: ' + $Draft)
  exit 0
}
if ($TrySend -and $mode -ne 'live') {
  Write-Output ('DRAFT (mode=' + $mode + ', not sent): ' + $Draft)
  exit 0
}
Write-Output ('DRAFT (not sent): ' + $Draft)
exit 0
