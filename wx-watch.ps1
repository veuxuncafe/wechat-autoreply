#requires -version 5.1
<#
  wx-watch.ps1 - the auto-reply loop.

  What it does, once per round:
    1. silently captures the chat area of the WeChat window (PrintWindow, flag 2, so it
       works while WeChat sits behind other windows and never steals focus)
    2. compares the frame hash with the previous one - identical means "no new message",
       and nothing else happens (no model call, no cost)
    3. when the frame DID change, it hands the new frame to a fresh one-shot agent run
       (`dsh --profile headless --patch wx-model-patch.yml -`) whose only job is to read
       the image and answer either "SKIP" or "INBOUND: ... / REPLY: ..."
    4. that answer is passed to wx-record.ps1, which is the only component allowed to
       touch WeChat, and which itself refuses to type anything while state\mode.txt says
       "dryrun"

  The model never gets the ability to send: this script owns the sending, and wx-record
  owns the policy. That split is deliberate.

  Runs OUTSIDE the DSH file sandbox - inside it, UIPI blocks PrintWindow and every
  cross-process UI call. Example:

    powershell -NoProfile -ExecutionPolicy Bypass -File wx-watch.ps1 -IntervalSec 15

  Options:
    -Once             one round and exit (smoke test)
    -NoModel          capture + change detection only, never call the model
    -MaxRounds N      stop after N rounds (0 = keep going)
    -Force            ignore the "frame unchanged" shortcut and run one model round
    -IntervalSec N    seconds between rounds (default 15)
    -ModelTimeoutSec N  give up on a model run after N seconds (default 240)
#>
param(
  [int]$IntervalSec = 15,
  [int]$MaxRounds = 0,
  [switch]$Once,
  [switch]$NoModel,
  [switch]$Force,
  [int]$ModelTimeoutSec = 240,
  # Proactive "start a new topic" policy. The owner asked the bot to keep the conversation alive
  # instead of going silent when the friend stops replying (and to treat him as a peer agent): the
  # moment he has been quiet for longer than ProactiveIdleSec the loop opens a new topic itself.
  # It is still bounded by a daily cap, a cap on unanswered streaks and a night window, so it can
  # never turn into a spammer.
  [int]$ProactiveIdleSec = 60,
  # The owner asked for unlimited proactive messages ("每天你都可以不限次数主动找他聊天"), so the
  # daily count cap is gone (0 = no cap). Instead the wait between topics grows with every message
  # he did not answer (60s -> 4min -> 16min -> 1h, capped) so an ignored account is never flooded.
  [int]$ProactiveMaxPerDay = 0,
  [int]$ProactiveMaxConsec = 0,
  [int]$ProactiveQuietFrom = 0,
  [int]$ProactiveQuietTo = 7,
  [switch]$ForceProactive
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'wx-core.ps1')
. (Join-Path $PSScriptRoot 'wx-ocr-lib.ps1')
. (Join-Path $PSScriptRoot 'wx-shot-lib.ps1')

$script:NodeExe = (Join-Path $env:APPDATA 'dsh-tauri\runtime\node.exe')
$script:DshBin = (Join-Path $env:APPDATA 'dsh-tauri\dependencies\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js')
$script:DshPatch = Join-Path $PSScriptRoot 'wx-model-patch.yml'
$script:PromptFile = Join-Path $PSScriptRoot 'reply-prompt-text.txt'
$script:ProactivePromptFile = Join-Path $PSScriptRoot 'proactive-prompt-text.txt'
$script:TargetTitle = $script:WxTargetTitle   # defined in wx-core.ps1, keeps this file pure ASCII
# Multi-contact: the active contact supplies the window title and both prompt
# texts. wx-contacts.ps1 / the panel own the store; here we only read it, and the
# rewritten prompt files under state\ are what the model call actually reads.
try {
  $ac = Get-WxActiveContact
  if ($ac) {
    if ($ac.name) { $script:TargetTitle = [string]$ac.name }
    $pf = Resolve-WxPromptFiles -Contact $ac
    if ($pf) {
      $script:PromptFile = $pf.Reply
      $script:ProactivePromptFile = $pf.Proactive
    }
  }
} catch { }
# WeChat flushes the message store to these files as messages arrive, so their mtime is a
# ~0.2s wake-up signal instead of a blind poll. The frame hash still gates the real work,
# and a backstop capture keeps a missed write from going unnoticed.
$script:DbWatch = @(
  '<you>\Documents\xwechat_files\<your-wxid>\db_storage\message\message_0.db-wal',
  '<you>\Documents\xwechat_files\<your-wxid>\db_storage\message\message_fts.db-wal',
  '<you>\Documents\xwechat_files\<your-wxid>\db_storage\message\message_0.db'
)
$script:CaptureScript = Join-Path $PSScriptRoot 'wx-capture.ps1'
$script:RecordScript = Join-Path $PSScriptRoot 'wx-record.ps1'
# Bump this whenever the way a frame is read changes (OCR filters, crop fractions, ...): a frame
# the old reader silently misread is then read again instead of being written off as handled.
$script:ReaderVersion = 3

if (-not $env:DSH_HOME) { $env:DSH_HOME = (Join-Path $env:USERPROFILE '.dsh') }

function Write-WatchLog {
  param([string]$Message)
  $line = '{0} | {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -LiteralPath (Join-Path $script:WxRoot 'logs\watch.log') -Value $line -Encoding UTF8
}

# Sleep only the part of the poll interval that this round has not already spent, so the
# cadence between two captures is IntervalSec and not IntervalSec + capture time.
function Wait-PollGap {
  param([long]$ElapsedMs)
  $waitMs = ($IntervalSec * 1000) - [int]$ElapsedMs
  if ($waitMs -gt 0) { Start-Sleep -Milliseconds $waitMs }
}

function Get-WatchState {
  $p = Join-Path $script:WxRoot 'state\watch.json'
  if (-not (Test-Path $p)) { return [pscustomobject]@{ lastSha16 = ''; lastAction = ''; rounds = 0; modelCalls = 0; events = 0; reader = 0; lastSide = ''; lastSideTs = ''; pcDate = ''; pcCount = 0; pcConsec = 0; pcLastTs = '' } }
  try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return [pscustomobject]@{ lastSha16 = ''; lastAction = ''; rounds = 0; modelCalls = 0; events = 0; reader = 0; lastSide = ''; lastSideTs = ''; pcDate = ''; pcCount = 0; pcConsec = 0; pcLastTs = '' } }
}

function Set-WatchState {
  param($State)
  $p = Join-Path $script:WxRoot 'state\watch.json'
  $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $p -Encoding UTF8
}

# Capture the frame in-process (wx-shot-lib.ps1). Spawning wx-capture.ps1 as a child used
# to cost about a second of PowerShell start-up per event, which is pure latency here.
function Get-CaptureFrame {
  param([string]$Area = 'chatctx')
  return (Invoke-WxShot -Area $Area -Method PrintWindow)
}

# One cheap number that changes whenever WeChat writes the message store.
function Get-WxDbStamp {
  $best = 0L
  foreach ($f in $script:DbWatch) {
    try {
      if (Test-Path -LiteralPath $f) {
        $t = (Get-Item -LiteralPath $f).LastWriteTimeUtc.Ticks
        if ($t -gt $best) { $best = $t }
      }
    } catch { }
  }
  return $best
}

# Wait for the message store to be written (fast path, ~0.25s) or for the backstop timer.
function Wait-WxEvent {
  param([int]$BackstopSec = 12)
  $base = Get-WxDbStamp
  $deadline = (Get-Date).AddSeconds($BackstopSec)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    $now = Get-WxDbStamp
    if ($now -ne $base) { return 'db' }
  }
  return 'timer'
}

# OCR the frame locally (no model, no network, ~0.15s) and turn it into "title + ordered
# bubbles with a side". The side of the newest bubble is decided here, in code, by x
# position - that removes the whole class of "the model picked the wrong bubble" errors.
function Get-FrameTranscript {
  param([string]$ImagePath = '')
  # UIA first: verbatim text, no image and no OCR. Only when the UIA tree is missing or exposes
  # no message row at all do we fall back to the screenshot + Windows OCR path.
  $u = $null
  if (Get-Command Get-WxUiaFrame -ErrorAction SilentlyContinue) { $u = Get-WxUiaFrame }
  if ($u -and $u.Blocks.Count -gt 0) {
    return [pscustomobject]@{ Ok = $true; OcrMs = $u.Ms; Lines = $u.Lines; Title = $u.Title; Blocks = $u.Blocks; Transcript = $u.Transcript; Source = 'uia' }
  }
  if (-not $ImagePath) {
    $fr = Get-CaptureFrame -Area 'chatctx'
    if ($fr) { $ImagePath = $fr.File }
  }
  if (-not $ImagePath) {
    return [pscustomobject]@{ Ok = $false; Error = 'no UIA tree and no screenshot'; OcrMs = 0; Lines = 0; Title = ''; Blocks = @(); Transcript = ''; Source = 'none' }
  }
  try {
    $ocr = Invoke-WxOcr -Path $ImagePath
    $t = Get-WxTranscript -Lines $ocr.Lines -ImageWidth $ocr.Width -ImageHeight $ocr.Height
    return [pscustomobject]@{ Ok = $true; OcrMs = $ocr.Ms; Lines = $ocr.Lines.Count; Title = $t.Title; Blocks = $t.Blocks; Transcript = $t.Transcript; Source = 'ocr' }
  } catch {
    return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message; OcrMs = 0; Lines = 0; Title = ''; Blocks = @(); Transcript = ''; Source = 'ocr' }
  }
}

# One-shot agent run. The task goes in through stdin and comes back through a redirect
# file, so Chinese text never travels through a command line or the console code page.
function Invoke-ModelDraft {
  param([string]$Transcript, [string]$PromptFile = '', [hashtable]$Vars = @{})

  if (-not (Test-Path $script:NodeExe)) { return [pscustomobject]@{ ok = $false; error = 'node.exe not found' } }
  if (-not (Test-Path $script:DshBin)) { return [pscustomobject]@{ ok = $false; error = 'dsh bin.js not found' } }
  # The reply prompt is the default, but the proactive "start a new topic" prompt goes through
  # the exact same one-shot agent path, just with a different template and extra placeholders.
  if (-not $PromptFile) { $PromptFile = $script:PromptFile }
  if (-not (Test-Path $PromptFile)) { return [pscustomobject]@{ ok = $false; error = ('prompt file not found: ' + $PromptFile) } }

  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $stateDir = Join-Path $script:WxRoot 'state'
  $inFile = Join-Path $stateDir ('ask-' + $stamp + '.txt')
  $outFile = Join-Path $stateDir ('answer-' + $stamp + '.txt')
  $errFile = Join-Path $stateDir ('answer-' + $stamp + '.err.txt')

  $template = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
  $task = $template.Replace('{{TRANSCRIPT}}', $Transcript)
  foreach ($k in @($Vars.Keys)) { $task = $task.Replace('{{' + $k + '}}', [string]$Vars[$k]) }
  [System.IO.File]::WriteAllText($inFile, $task, (New-Object System.Text.UTF8Encoding($false)))

  $argList = @($script:DshBin, '--profile', 'headless')
  if (Test-Path $script:DshPatch) { $argList += @('--patch', $script:DshPatch) }
  $argList += '-'

  $proc = $null
  try {
    $proc = Start-Process -FilePath $script:NodeExe -ArgumentList $argList -NoNewWindow -PassThru `
      -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
  } catch {
    return [pscustomobject]@{ ok = $false; error = ('spawn failed: ' + $_.Exception.Message) }
  }

  $finished = $proc.WaitForExit($ModelTimeoutSec * 1000)
  if (-not $finished) {
    try { $proc.Kill() } catch { }
    return [pscustomobject]@{ ok = $false; error = ('model run timed out after ' + $ModelTimeoutSec + 's') }
  }

  $raw = ''
  if (Test-Path $outFile) { $raw = (Get-Content -LiteralPath $outFile -Raw -Encoding UTF8) }
  $err = ''
  if (Test-Path $errFile) { $err = (Get-Content -LiteralPath $errFile -Raw -Encoding UTF8) }

  $inbound = ''
  $reply = ''
  # This script stays pure ASCII (a BOM-less .ps1 is decoded as GBK by PowerShell 5.1,
  # which would corrupt a literal full-width colon), so build that character at runtime.
  $fullWidthColon = [string][char]0xFF1A
  foreach ($line in ($raw -split "`r?`n")) {
    $l = $line.Replace($fullWidthColon, ':')
    if ($l -match '^\s*INBOUND\s*:\s*(.+?)\s*$') { $inbound = $Matches[1] }
    elseif ($l -match '^\s*REPLY\s*:\s*(.+?)\s*$') { $reply = $Matches[1] }
  }

  $skip = (-not $reply) -and ($raw -match 'SKIP')
  return [pscustomobject]@{
    ok      = $true
    skip    = $skip
    inbound = $inbound
    reply   = $reply
    raw     = $raw
    stderr  = $err
    exit    = $proc.ExitCode
  }
}

function Send-DraftToRecorder {
  param([string]$Inbound, [string]$Draft, [string]$FrameSha, [switch]$Retry, [switch]$Instant)
  $payload = [pscustomobject]@{ inbound = $Inbound; draft = $Draft; frameSha = $FrameSha; title = $script:TargetTitle }
  $f = Join-Path $script:WxRoot ('state\record-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.json')
  $payload | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $f -Encoding UTF8
  # -TrySend is always passed on purpose: wx-record owns the policy and only types into WeChat
  # while state\mode.txt says "live". Without this switch the entire live path silently degraded
  # to draft-only logging, which silently ate two real replies before it was caught.
  # Capture decoding: PowerShell decodes a native child's stdout with [Console]::OutputEncoding.
  # wx-record echoes Chinese back ("SENT: <draft>"), so without this the log shows GBK mojibake and
  # a real send looks like garbage in the history.
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:RecordScript, '-FromJson', $f, '-TrySend')
  if ($Retry) { $a += '-Retry' }
  if ($Instant) { $a += '-Instant' }
  try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
  $out = & powershell.exe @a 2>&1
  return (($out | ForEach-Object { [string]$_ }) -join ' ')
}

# The proactive "he has gone quiet, go start a topic" decision lives in exactly one place, because
# it is consulted twice: from the quiet path (an unchanged frame, where nothing else would ever
# wake the loop) and from the normal path once a frame has been read. It must never disagree.
function Test-WxProactiveDue {
  param([Parameter(Mandatory = $true)]$State)
  # Fail closed: an unparseable or missing timestamp yields -1, which can never look like a long
  # silence - a restart must not fire an instant topic.
  $idleSec = -1
  $lastTs = [string]$State.lastSideTs
  if ($lastTs) { try { $idleSec = [int]((Get-Date) - [datetime]::Parse($lastTs)).TotalSeconds } catch { $idleSec = -1 } }
  $pcDay = (Get-Date).ToString('yyyy-MM-dd')
  $pcCount = [int]$State.pcCount
  $pcConsec = [int]$State.pcConsec
  if ([string]$State.pcDate -ne $pcDay) { $pcCount = 0; $pcConsec = 0 }
  $sinceAttempt = 999999
  $pcLast = [string]$State.pcLastTs
  if ($pcLast) { try { $sinceAttempt = [int]((Get-Date) - [datetime]::Parse($pcLast)).TotalSeconds } catch { $sinceAttempt = 999999 } }
  $hour = (Get-Date).Hour
  $quiet = ($hour -ge $ProactiveQuietFrom -and $hour -lt $ProactiveQuietTo)
  # Unlimited topics, but back off while he is not answering: 60s once he has answered, then 4x
  # longer for every topic that went unanswered, capped at one hour.
  $waitSec = $ProactiveIdleSec * [Math]::Pow(4, $pcConsec)
  if ($waitSec -gt 3600) { $waitSec = 3600 }
  $capOk = ($ProactiveMaxPerDay -le 0 -or $pcCount -lt $ProactiveMaxPerDay)
  $streakOk = ($ProactiveMaxConsec -le 0 -or $pcConsec -lt $ProactiveMaxConsec)
  $due = ((-not $quiet) -and $capOk -and $streakOk -and ($idleSec -ge $waitSec) -and ($sinceAttempt -ge $waitSec))
  return [pscustomobject]@{ Due = $due; IdleSec = $idleSec; AttemptSec = $sinceAttempt; Count = $pcCount; Consec = $pcConsec; Quiet = $quiet; WaitSec = [int]$waitSec }
}

# ---- main loop ----------------------------------------------------------------

$mode = Get-WxMode
Write-WatchLog ('watch start: mode={0} interval={1}s once={2} noModel={3} read=uia-first(ocr-fallback)' -f $mode, $IntervalSec, [bool]$Once, [bool]$NoModel)

$state = Get-WatchState
$round = 0
$stop = $false

while (-not $stop) {
  $stopFlagPath = Join-Path $PSScriptRoot 'state\stop.flag'
  if (Test-Path -LiteralPath $stopFlagPath) {
    Add-WxLog 'INFO' 'stop flag detected - exiting because the control panel asked me to stop'
    $stop = $true
    continue
  }
  $round++
  $state.rounds = [int]$state.rounds + 1
  $roundSw = [System.Diagnostics.Stopwatch]::StartNew()

  # A failed send must never lose the reply: deliver one deferred draft per round, even when
  # no new message arrives. Five tries or half an hour, then give up loudly.
  $pend = @(Get-WxPending)
  if ($pend.Count -gt 1) {
    # He can fire off messages faster than the send throttle (20s) allows answers, so a backlog of
    # queued replies would arrive minutes late, each answering something already stale. Keep only
    # the newest: answering the latest message is what a person would do.
    $keep = $pend | Sort-Object { try { [datetime]::Parse([string]$_.ts) } catch { [datetime]::MinValue } } | Select-Object -Last 1
    foreach ($old in $pend) {
      if ($old -ne $keep) {
        Write-WatchLog ('dropping a stale queued reply (a newer one exists): ' + $old.draft)
        Remove-WxPending -Draft ([string]$old.draft)
      }
    }
    $pend = @($keep)
  }
  if ($pend.Count -gt 0 -and $mode -eq 'live' -and -not $NoModel) {
    $p = $pend[0]
    # An entry without a parseable timestamp is an artifact, not a pending reply: never let it
    # reach WeChat. Default to "expired" so a malformed queue entry fails closed.
    $ageMin = 9999
    try { $ageMin = ((Get-Date) - [datetime]::Parse([string]$p.ts)).TotalMinutes } catch { }
    # The repeated one-liner must arrive right after the message that triggered it, so an -Instant
    # entry expires in three minutes instead of half an hour.
    $ageSec = 999999
    try { $ageSec = ((Get-Date) - [datetime]::Parse([string]$p.ts)).TotalSeconds } catch { }
    $instantStale = ([bool]$p.instant -and $ageSec -gt 180)
    if ([string]::IsNullOrWhiteSpace([string]$p.draft) -or $ageMin -gt 30 -or [int]$p.tries -ge 5 -or $instantStale) {
      if ($instantStale) { Write-WatchLog ('the instant line went stale - dropping it: ' + $p.draft) }
      else { Write-WatchLog ('giving up on a deferred reply after ' + [int]$p.tries + ' tries: ' + $p.draft) }
      Add-WxLog 'GIVEUP' ('gave up on a queued reply after ' + [int]$p.tries + ' tries: "' + $p.draft + '"') | Out-Null
      Remove-WxPending -Draft ([string]$p.draft)
    } else {
      # Wait for the backoff window before touching WeChat again. The entry stays in the queue (so
      # the panel keeps showing that something is waiting) but is not retried every round.
      $dueIn = 0
      try { if ($p.nextTry) { $dueIn = [int]((Get-Date) - [datetime]::Parse([string]$p.nextTry)).TotalSeconds } } catch { $dueIn = 0 }
      if ($dueIn -lt 0) {
        Write-WatchLog ('queued reply is waiting for its next try in ' + [Math]::Abs($dueIn) + 's: ' + $p.draft)
      } else {
      $p.tries = [int]$p.tries + 1
      $p.nextTry = (Get-Date).AddSeconds((Get-WxRetryDelaySec -Tries ([int]$p.tries))).ToString('s')
      Set-WxPending $pend
      # Colour-based send verification can be a false negative (a just-sent green bubble sits
      # where the send button is), and sending the same draft twice would be worse than late.
      # So ask the chat itself: if the draft is already my newest message, it was delivered.
      $delivered = $false
      $t2 = Get-FrameTranscript -ImagePath ''
      if ($t2.Ok -and $t2.Blocks.Count -gt 0) {
        $lb = $t2.Blocks[$t2.Blocks.Count - 1]
        $flat = ([string]$p.draft) -replace '\s+', ''
        $needle = $flat.Substring(0, [Math]::Min(6, $flat.Length))
        if ($lb.Side -eq 'me' -and (($lb.Text -replace '\s+', '') -like ('*' + $needle + '*'))) { $delivered = $true }
      }
      if ($delivered) {
        Write-WatchLog ('deferred reply already delivered - dropping queue entry: ' + $p.draft)
        Remove-WxPending -Draft ([string]$p.draft)
      } else {
        $rres = Send-DraftToRecorder -Inbound ([string]$p.inbound) -Draft ([string]$p.draft) -FrameSha '' -Retry -Instant ([bool]$p.instant)
        Write-WatchLog ('retry deferred reply (try ' + [int]$p.tries + '): ' + $rres)
        # -cmatch, and the colon matters: "DRAFT (not sent): ..." was a match for 'SENT', which
        # silently deleted every queued reply in the same round that queued it.
        if ($rres -cmatch 'SENT:') { Remove-WxPending -Draft ([string]$p.draft) }
      }
      }
    }
  }

  # Sleep until WeChat writes the message store (fast path) or the backstop expires.
  if (-not $Once) { [void](Wait-WxEvent -BackstopSec $IntervalSec) }

  # A UIA frame needs no screenshot: the tree is both the content and the fingerprint.
  $frame = $null
  if (Get-Command Get-WxUiaFrame -ErrorAction SilentlyContinue) { $frame = Get-WxUiaFrame }
  if (-not $frame) { $frame = Get-CaptureFrame -Area 'chatctx' }
  if (-not $frame) {
    Write-WatchLog 'capture failed (WeChat window missing or blocked)'
    Set-WatchState $state
    if ($Once -or ($MaxRounds -gt 0 -and $round -ge $MaxRounds)) { $stop = $true; continue }
    Start-Sleep -Seconds 2
    continue
  }

  if ($frame.Blank) { Write-WatchLog ('frame looks blank, method=' + $frame.Method) }

  # A frame that the previous reader could not understand must not count as "handled": when the
  # reading logic changes, re-read the frame that is on screen right now (bump the version).
  $readerBump = ([int]$state.reader -ne $script:ReaderVersion)
  $changed = ($frame.Sha16 -ne $state.lastSha16) -or $readerBump
  if ($readerBump) { Write-WatchLog ('reader v{0} -> re-reading the current frame' -f $script:ReaderVersion) }
  if (-not $changed -and -not $Force) {
    # A friend who simply stops replying never changes the frame - and that is precisely the case
    # the owner wants a new topic in ("if he says nothing for a minute, go talk to him"), so the
    # proactive timer is checked here too and turns an otherwise idle round into a real one.
    $proactiveDue = $false
    if ((-not $NoModel) -and ($mode -eq 'live')) {
      $pdc = Test-WxProactiveDue -State $state
      if ($pdc.Due) {
        $proactiveDue = $true
        Write-WatchLog ('proactive topic is due ({0}s of silence) - re-reading the current frame to open one' -f $pdc.IdleSec)
      }
    }
    if (-not $proactiveDue) {
      if ($round % 10 -eq 0) { Write-WatchLog ('idle {0} rounds, sha16={1}' -f $round, $frame.Sha16) }
      Set-WatchState $state
      if ($Once -or ($MaxRounds -gt 0 -and $round -ge $MaxRounds)) { $stop = $true; continue }
      continue
    }
  }

  # New frame: keep a stable copy for the log, then read it locally with the Windows OCR
  # engine. No model is involved in reading the pane any more.
  $eventStamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $eventShot = ''
  if ($frame.File) {
    $eventShot = Join-Path (Get-WxShotDir) ('event-' + $eventStamp + '.png')
    try { Copy-Item -LiteralPath $frame.File -Destination $eventShot -Force } catch { $eventShot = $frame.File }
  }
  $state.lastSha16 = $frame.Sha16
  # Add-Member, not assignment: the state object came from JSON and has no "reader" slot yet,
  # so "=" threw ExceptionWhenSetting every single round.
  $state | Add-Member -NotePropertyName reader -NotePropertyValue $script:ReaderVersion -Force
  if ($changed) {
    $state.events = [int]$state.events + 1
    Write-WatchLog ('new frame {0}: sha16={1} shot={2}' -f $state.events, $frame.Sha16, $eventShot)
  } else {
    Write-WatchLog ('re-reading the unchanged frame for a proactive topic: sha16={0}' -f $frame.Sha16)
  }

  if ($frame.Method -eq 'uia') {
    $tr = [pscustomobject]@{ Ok = $true; OcrMs = $frame.Ms; Lines = $frame.Lines; Title = $frame.Title; Blocks = $frame.Blocks; Transcript = $frame.Transcript; Source = 'uia' }
  } else {
    $tr = Get-FrameTranscript -ImagePath $eventShot
  }
  if (-not $tr.Ok) {
    Write-WatchLog ('ocr failed: ' + $tr.Error)
    $state.lastAction = 'ocr-failed'
    Set-WatchState $state
    if ($Once -or ($MaxRounds -gt 0 -and $round -ge $MaxRounds)) { $stop = $true; continue }
    continue
  }
  $last = $null
  if ($tr.Blocks.Count -gt 0) { $last = $tr.Blocks[$tr.Blocks.Count - 1] }
  $lastSide = if ($last) { $last.Side } else { 'none' }
  $lastText = if ($last) { $last.Text } else { '' }
  Write-WatchLog ('read: src={0} title="{1}" {2}ms blocks={3} newest={4} "{5}"' -f $tr.Source, $tr.Title, $tr.OcrMs, $tr.Blocks.Count, $lastSide, $lastText)
  # Remember who wrote the newest message and when that last flipped: the proactive "he has gone
  # quiet" timer counts from here. Add-Member (not "=") because the state came from JSON.
  $prevSide = [string]$state.lastSide
  $state | Add-Member -NotePropertyName lastSide -NotePropertyValue $lastSide -Force
  # Only a side flip restarts the clock. Refreshing it on every frame made "idle" always read 0,
  # so the proactive branch could never fire outside -ForceProactive.
  if ($lastSide -ne $prevSide) { $state | Add-Member -NotePropertyName lastSideTs -NotePropertyValue ((Get-Date).ToString('s')) -Force }

  # Two decisions that used to cost a model call every time (and that the model used to get
  # wrong) are now made here, from the transcript, for free. The title check tolerates OCR
  # junk around the name but still refuses to answer any other conversation.
  if ($tr.Title -ne $script:TargetTitle -and $tr.Title -notlike ('*' + $script:TargetTitle + '*')) {
    Write-WatchLog ('not the target chat (title="{0}") - nothing to do' -f $tr.Title)
    $state.lastAction = 'other-chat'
    Set-WatchState $state
    if ($Once -or ($MaxRounds -gt 0 -and $round -ge $MaxRounds)) { $stop = $true; continue }
    continue
  }
  if ($lastSide -ne 'them') {
    # The newest message is mine, so normally there is nothing to do. The owner asked the bot to
    # keep the conversation alive instead of going silent, so after a quiet stretch it opens a new
    # topic itself - bounded by a daily cap, a cap on unanswered streaks and a night window.
    # The owner's rule is "if he has said nothing for more than a minute, go start a topic", so the
    # idle test is in seconds (fail-closed: an unparseable timestamp yields -1, never a long silence).
    # The owner's rule is "if he has said nothing for more than a minute, go start a topic": the
    # decision (idle seconds, daily cap, unanswered streak, night window) comes from the one shared
    # helper so this branch and the quiet path above can never disagree.
    $pd = Test-WxProactiveDue -State $state
    $idleSec = $pd.IdleSec
    $sinceAttempt = $pd.AttemptSec
    $pcCount = $pd.Count
    $pcConsec = $pd.Consec
    $pcDay = (Get-Date).ToString('yyyy-MM-dd')
    $canProactive = ((-not $NoModel) -and ($mode -eq 'live') -and $pd.Due)
    if ($ForceProactive -and (-not $NoModel) -and ($mode -eq 'live')) { $canProactive = $true }
    if ($canProactive) {
      Write-WatchLog ('quiet for {0}s (last attempt {1}s ago, next topic due after {2}s idle) - starting a new topic myself, today {3} sent, streak {4}' -f $idleSec, $sinceAttempt, $pd.WaitSec, $pcCount, $pcConsec)
      # Hand the model what I already sent lately: without it it happily cooked up "这两天降温了"
      # twice in one evening (the exact-text dedup cannot see near-repeats).
      $wxs = Get-WxState
      $recentList = (@($wxs.replied) | Select-Object -Last 6 | ForEach-Object { if ($_.text) { '- ' + [string]$_.text } }) -join "`n"
      if (-not $recentList) { $recentList = '(none)' }
      $pa = Invoke-ModelDraft -Transcript $tr.Transcript -PromptFile $script:ProactivePromptFile -Vars @{ NOW = (Get-Date).ToString('yyyy-MM-dd HH:mm'); RECENT = $recentList }
      $state.modelCalls = [int]$state.modelCalls + 1
      if (-not $pa.ok) {
        Write-WatchLog ('proactive model call failed: ' + $pa.error)
        $state.lastAction = 'proactive-failed'
      } elseif ($pa.skip -or -not $pa.reply) {
        Write-WatchLog ('proactive model says SKIP (exit={0})' -f $pa.exit)
        $state.lastAction = 'proactive-skip'
      } else {
        $pr = $pa.reply.Trim().Trim('"').Trim("'")
        if ($pr.Length -gt 200) { $pr = $pr.Substring(0, 200) }
        Write-WatchLog ('proactive topic: ' + $pr)
        # The inbound marker is deliberately unique: wx-record deduplicates by inbound text, and
        # two different proactive messages must never look like a repeat of one message.
        $marker = '(proactive ' + (Get-Date).ToString('HH:mm:ss') + ')'
        $result = Send-DraftToRecorder -Inbound $marker -Draft $pr -FrameSha $frame.Sha16
        Write-WatchLog ('recorder: ' + $result)
        if ($result -cmatch 'SENT:') { $pcCount++; $pcConsec++ }
        else { Write-WatchLog 'the proactive message did not go out - it is not counted as a sent topic' }
        $state.lastAction = 'proactive'
      }
      $state | Add-Member -NotePropertyName pcDate -NotePropertyValue $pcDay -Force
      $state | Add-Member -NotePropertyName pcCount -NotePropertyValue $pcCount -Force
      $state | Add-Member -NotePropertyName pcConsec -NotePropertyValue $pcConsec -Force
      $state | Add-Member -NotePropertyName pcLastTs -NotePropertyValue ((Get-Date).ToString('s')) -Force
    } else {
      Write-WatchLog ('the newest message is mine - nothing to do (idle {0}s, attempt {1}s ago, next topic due after {2}s idle, today {3} sent, streak {4})' -f $idleSec, $sinceAttempt, $pd.WaitSec, $pcCount, $pcConsec)
      $state.lastAction = 'mine'
    }
    Set-WatchState $state
    if ($Once -or ($MaxRounds -gt 0 -and $round -ge $MaxRounds)) { $stop = $true; continue }
    continue
  }

  # He answered, so the "no reply from him" streak that the proactive cap counts is over.
  $state | Add-Member -NotePropertyName pcConsec -NotePropertyValue 0 -Force

  if ($NoModel) {
    $state.lastAction = 'no-model'
    Set-WatchState $state
    if ($Once -or ($MaxRounds -gt 0 -and $round -ge $MaxRounds)) { $stop = $true; continue }
    continue
  }

  # The owner's rules, counted here in code because a model cannot count characters reliably:
  # anything over 120 characters gets one fixed line instead of an answer (he likes pasting whole
  # essays), while everything up to 120 characters is answered properly. Per the owner's word this
  # line is not rate-limited or de-duplicated: every single long message gets it at once.
  $inLen = 0
  if ($lastText) { $inLen = $lastText.Length }
  if ($inLen -gt 120) {
    $canned = '傻B旭阳把我DeepSeek干冒烟了'
    Write-WatchLog ('inbound is {0} chars (> 120) - sending the fixed line instead of a reply' -f $inLen)
    $inboundTag = [string]$lastText
    if ($inboundTag.Length -gt 80) { $inboundTag = $inboundTag.Substring(0, 80) }
    $result = Send-DraftToRecorder -Inbound $inboundTag -Draft $canned -FrameSha $frame.Sha16 -Instant
    Write-WatchLog ('recorder: ' + $result)
    $state.lastAction = 'canned'
    Set-WatchState $state
    if ($Once -or ($MaxRounds -gt 0 -and $round -ge $MaxRounds)) { $stop = $true; continue }
    continue
  }
  $answer = Invoke-ModelDraft -Transcript $tr.Transcript -Vars @{ INBOUND_LEN = $inLen }
  $state.modelCalls = [int]$state.modelCalls + 1

  if (-not $answer.ok) {
    Write-WatchLog ('model call failed: ' + $answer.error)
    $state.lastAction = 'model-failed'
  }
  elseif ($answer.skip -or -not $answer.reply) {
    Write-WatchLog ('model says SKIP (exit={0})' -f $answer.exit)
    $state.lastAction = 'skip'
  }
  else {
    $reply = $answer.reply.Trim().Trim('"').Trim("'")
    if ($reply.Length -gt 200) { $reply = $reply.Substring(0, 200) }
    $inbound = $answer.inbound
    if (-not $inbound) { $inbound = $lastText }
    Write-WatchLog ('draft for "{0}": {1}' -f $inbound, $reply)
    $result = Send-DraftToRecorder -Inbound $inbound -Draft $reply -FrameSha $frame.Sha16
    Write-WatchLog ('recorder: ' + $result)
    # "SENT"/"DRAFT"/"SEEN" are the recorder's verdicts; anything else means it blew up before
    # deciding (its library failed to load once and the reply was silently lost). Keep the draft.
    if (($result -notmatch 'SENT:') -and ($result -notmatch 'DRAFT') -and ($result -notmatch 'SEEN')) {
      Add-WxPending -Inbound $inbound -Draft $reply
      Write-WatchLog 'the recorder reported no verdict - the reply was queued for retry'
      $state.lastAction = 'recorder-failed'
    } else {
      $state.lastAction = 'drafted'
    }
  }

  Set-WatchState $state
  if ($Once -or ($MaxRounds -gt 0 -and $round -ge $MaxRounds)) { $stop = $true; continue }
  # A follow-up message may have landed while the model was thinking: loop straight back to
  # the event wait instead of sitting out an interval.
}

Write-WatchLog ('watch stop after {0} rounds' -f $round)
Write-Output ('rounds={0} events={1} modelCalls={2} lastAction={3}' -f $round, $state.events, $state.modelCalls, $state.lastAction)
