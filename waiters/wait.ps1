#requires -Version 7
<#
.SYNOPSIS
    dsh-no-poll waiter (PowerShell 7+, Windows-native, no dependencies).

.DESCRIPTION
    Waiting for a long task should not be the model's job.
        BAD  : the model repeatedly asks "is it done yet?" -- every ask costs a full
               round trip plus context, and the task does not finish any sooner.
        GOOD : a background process waits; when it exits, the host wakes the model.
               Model turns spent waiting = 0.

    Use this on Windows when Python is not available: .NET ships ClientWebSocket,
    so nothing needs installing. Otherwise prefer wait.py (cross-platform).

    EXIT CONTRACT -- THREE STATES, NOTHING ELSE
        0  DONE      the system explicitly reported success
        1  FAILED    the system explicitly reported failure,
                     OR the system was unreachable after retries were exhausted
        (no exit)    WAITING -- the process blocks. This is the normal, expected state.

        There is no timeout and no giving up. A task that is queued, slow, or
        apparently stuck is still waited on. Do not kill this process to "check"
        on the task -- that is what kills the task.

        FAILED is deliberately STRICT: only an explicit verdict from the upstream
        system, or total unreachability after retries. A slow or queued task is
        never reported as failed.

    The LAST line on stdout is machine-readable: <TAG><TAB><detail>
    Progress goes to the console and is silenced by -Quiet.

.EXAMPLE
    ./wait.ps1 comfyui -PromptId <id> -ClientId <id>
.EXAMPLE
    ./wait.ps1 http -Url http://127.0.0.1:8188/queue -Until '"queue_running"'
.EXAMPLE
    ./wait.ps1 file -Path ./out.png
.EXAMPLE
    ./wait.ps1 probe -Url http://127.0.0.1:8188/system_stats
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('comfyui', 'http', 'file', 'probe')]
    [string]$Command,

    # comfyui
    [string]$PromptId,
    [string]$ClientId = '',
    [string]$HostName = '127.0.0.1',
    [int]$Port = 8188,
    [switch]$Poll,

    # http / probe
    [string]$Url,
    [string]$Until = '',
    [string]$Expect = '',

    # file
    [string]$Path,
    [string]$UntilMatch = '',

    # common
    [double]$IntervalSeconds = 3,
    [double]$RequestTimeoutSeconds = 10,
    [int]$ConnRetries = 2,
    [double]$ConnRetryDelaySeconds = 150,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$EXIT_DONE = 0
$EXIT_FAILED = 1

function Say([string]$Message) { if (-not $Quiet) { Write-Host $Message } }

# `MachineDetail` overrides what goes on the machine-readable last line. Network errors
# carry OS-localised text (a Chinese Windows reports Chinese) and the last line is meant
# to be parsed, so callers pass a stable ASCII detail there while the localised message
# stays on the console for the human.
function Finish([int]$Code, [string]$Tag, [string]$Detail, [string]$MachineDetail = '') {
    if (-not $Quiet) { Write-Host "  [$Tag] $Detail" }
    if ($MachineDetail) { "$Tag`t$MachineDetail" } else { "$Tag`t$Detail" }
    exit $Code
}

$script:Stopwatch = [Diagnostics.Stopwatch]::StartNew()
function Elapsed { [math]::Round($script:Stopwatch.Elapsed.TotalSeconds, 1) }

# ---------------------------------------------------------------- probe -----
if ($Command -eq 'probe') {
    if (-not $Url) { Finish $EXIT_FAILED 'FAILED' 'probe requires -Url' }
    try {
        $response = Invoke-WebRequest $Url -TimeoutSec $RequestTimeoutSeconds
        $body = [string]$response.Content
        $matched = if ($Expect) { $body -match $Expect } else { $true }
        if ($matched) { Finish $EXIT_DONE 'DONE' "$Url ($($body.Length) chars)" }
        Finish $EXIT_FAILED 'FAILED' "$Url did not match $Expect"
    } catch {
        Finish $EXIT_FAILED 'FAILED' "unreachable: $($_.Exception.Message.Split([char]10)[0])" "unreachable: $Url"
    }
}

# ----------------------------------------------------------------- http -----
if ($Command -eq 'http') {
    if (-not $Url) { Finish $EXIT_FAILED 'FAILED' 'http requires -Url' }
    $consecutiveFailures = 0
    while ($true) {
        try {
            $response = Invoke-WebRequest $Url -TimeoutSec $RequestTimeoutSeconds
            $consecutiveFailures = 0
            $body = [string]$response.Content
            if (-not $Until -or $body -match $Until) {
                Finish $EXIT_DONE 'DONE' "$Url matched after $(Elapsed)s"
            }
            Say "  ... $(Elapsed)s, not matched yet"
        } catch {
            $consecutiveFailures++
            Say "  ... $(Elapsed)s, request failed ($($consecutiveFailures)/$($ConnRetries + 1))"
            if ($consecutiveFailures -gt $ConnRetries) {
                Finish $EXIT_FAILED 'FAILED' "unreachable after $consecutiveFailures attempts: $($_.Exception.Message.Split([char]10)[0])" "unreachable: $Url ($consecutiveFailures attempts)"
            }
            Start-Sleep -Seconds $ConnRetryDelaySeconds
            continue
        }
        Start-Sleep -Milliseconds ([Math]::Max(200, $IntervalSeconds * 1000))
    }
}

# ----------------------------------------------------------------- file -----
if ($Command -eq 'file') {
    if (-not $Path) { Finish $EXIT_FAILED 'FAILED' 'file requires -Path' }
    while ($true) {
        if (Test-Path -LiteralPath $Path) {
            if (-not $UntilMatch) { Finish $EXIT_DONE 'DONE' "$Path appeared after $(Elapsed)s" }
            try {
                $body = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
                if ($body -match $UntilMatch) { Finish $EXIT_DONE 'DONE' "$Path matched after $(Elapsed)s" }
            } catch { }
        }
        Start-Sleep -Milliseconds ([Math]::Max(200, $IntervalSeconds * 1000))
    }
}

# -------------------------------------------------------------- comfyui -----
if (-not $PromptId) { Finish $EXIT_FAILED 'FAILED' 'comfyui requires -PromptId' }
$base = "http://${HostName}:${Port}"

# THREE-STATE query. Collapsing this is how a running task gets declared dead:
#   ok = $true   query succeeded, the job is present
#   ok = $false  query succeeded, the job is genuinely absent
#   ok = $null   the QUERY ITSELF FAILED (network, server restarting) -- not "absent"
function Get-HistoryEntry {
    try {
        $history = Invoke-RestMethod "$base/history/$PromptId" -TimeoutSec $RequestTimeoutSeconds
    } catch {
        return @{ ok = $null; entry = $null }
    }
    $keys = @($history.PSObject.Properties.Name)
    if ($keys.Count -gt 0) { return @{ ok = $true; entry = $history.$($keys[0]) } }
    return @{ ok = $false; entry = $null }
}

# Is the job queued? True means it is definitely still alive.
# Returns $true / $false / $null (the queue query itself failed).
function Test-InQueue {
    try {
        $queue = Invoke-RestMethod "$base/queue" -TimeoutSec $RequestTimeoutSeconds
    } catch {
        return $null
    }
    foreach ($key in @('queue_running', 'queue_pending')) {
        foreach ($item in @($queue.$key)) {
            if ($null -eq $item) { continue }
            if ($item -is [array] -and $item.Count -gt 1 -and $item[1] -eq $PromptId) { return $true }
            if (($item.PSObject.Properties.Name -contains 'prompt_id') -and $item.prompt_id -eq $PromptId) { return $true }
        }
    }
    return $false
}

# Extract the output list from a history entry.
#
# History is the authoritative record: it names every output node and the files each
# produced. A workflow with several SaveImage nodes is only described correctly here --
# counting `executed` events gives a number, not the filenames the caller needs next.
function Get-EntryOutputs([object]$Entry, [int]$Limit = 6) {
    $result = @{ count = 0; files = @() }
    if ($null -eq $Entry) { return $result }
    $outputs = $Entry.outputs
    if ($null -eq $outputs) { return $result }
    $names = @($outputs.PSObject.Properties.Name)
    $files = @()
    foreach ($key in $names) {
        $nodeOutput = $outputs.$key
        if ($null -eq $nodeOutput) { continue }
        foreach ($kind in @($nodeOutput.PSObject.Properties.Name)) {
            $items = $nodeOutput.$kind
            if ($items -isnot [array]) { continue }
            foreach ($item in $items) {
                if ($null -ne $item -and $item.filename) { $files += [string]$item.filename }
            }
        }
    }
    if ($Limit -gt 0 -and $files.Count -gt $Limit) { $files = @($files[0..($Limit - 1)]) }
    return @{ count = $names.Count; files = $files }
}

# Map a history entry to an outcome, or $null while it is still running.
# STRICT: failure is reported only when ComfyUI itself says so.
function Test-Entry([object]$Entry) {
    if ($null -eq $Entry) { return $null }
    $statusStr = [string]$Entry.status.status_str

    if ($Entry.status.completed -eq $true) {
        if ($statusStr -and $statusStr -ne 'success') { return @('FAILED', $EXIT_FAILED, $statusStr) }
        $out = Get-EntryOutputs $Entry
        $detail = "$($out.count) output node(s)"
        if ($out.files.Count -gt 0) { $detail += ": " + ($out.files -join ', ') }
        return @('DONE', $EXIT_DONE, $detail)
    }
    if ($statusStr -in @('error', 'failed')) { return @('FAILED', $EXIT_FAILED, $statusStr) }
    return $null
}

# Build the DONE detail when the entry is NOT already in hand (event-driven path).
function Get-DoneDetail([int]$FallbackNodes = -1) {
    $state = Get-HistoryEntry
    if ($state.ok -ne $true) {
        if ($FallbackNodes -ge 0) { return "$(Elapsed)s, $FallbackNodes output event(s)" }
        return "$(Elapsed)s"
    }
    $out = Get-EntryOutputs $state.entry
    $detail = "$(Elapsed)s, $($out.count) output node(s)"
    if ($out.files.Count -gt 0) { $detail += ": " + ($out.files -join ', ') }
    return $detail
}

# Race guard, not polling: the job can finish between "submitted" and "connected".
$probe = Get-HistoryEntry
if ($probe.ok -eq $true) {
    $verdict = Test-Entry $probe.entry
    if ($verdict) { Finish $verdict[1] $verdict[0] "$($verdict[2]) (finished before we connected, $(Elapsed)s)" }
}

# Fallback: poll /history INSIDE THIS PROCESS. The model still spends zero turns.
function Invoke-PollFallback([string]$Reason) {
    Say "  (polling /history in-process: $Reason)"
    $consecutiveQueryFailures = 0
    while ($true) {
        $state = Get-HistoryEntry
        if ($state.ok -eq $true) {
            $consecutiveQueryFailures = 0
            $verdict = Test-Entry $state.entry
            if ($verdict) { Finish $verdict[1] $verdict[0] "$($verdict[2]) (polled, $(Elapsed)s)" }
        } elseif ($null -eq $state.ok) {
            # Could not ask -- not the same as "it is gone".
            $consecutiveQueryFailures++
            Say "  ... $(Elapsed)s, query failed ($consecutiveQueryFailures/$($ConnRetries + 1))"
            if ($consecutiveQueryFailures -gt $ConnRetries) {
                Finish $EXIT_FAILED 'FAILED' "could not reach $base after $consecutiveQueryFailures attempts (waited $(Elapsed)s)" "unreachable: $base ($consecutiveQueryFailures attempts)"
            }
            Start-Sleep -Seconds $ConnRetryDelaySeconds
            continue
        } else {
            $consecutiveQueryFailures = 0
            $inQueue = Test-InQueue
            if ($inQueue -eq $true) {
                Say "  ... $(Elapsed)s, still queued"
            } elseif ($null -eq $inQueue) {
                # Queue query failed; draw no conclusion from it.
            } else {
                # Absent from both. Keep waiting: the contract is to wait, never to
                # declare a task dead. There is deliberately no give-up branch.
                Say "  ... $(Elapsed)s, not in history or queue (still waiting)"
            }
        }
        Start-Sleep -Milliseconds ([Math]::Max(200, $IntervalSeconds * 1000))
    }
}

if ($Poll -or -not $ClientId) {
    if (-not $ClientId -and -not $Quiet) {
        Say "  note: no -ClientId given. ComfyUI directs execution events at the"
        Say "        submitting client, so a random id receives none. Polling instead."
    }
    Invoke-PollFallback 'no client id'
}

# Event-driven path. Retry the connection; if it never succeeds, that is a failure
# to REACH the system -- reported as FAILED, never as a verdict about the task.
$ws = $null
$lastError = $null
for ($attempt = 1; $attempt -le ($ConnRetries + 1); $attempt++) {
    try {
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
        $ws.ConnectAsync([Uri]"ws://${HostName}:${Port}/ws?clientId=$ClientId",
                         [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        $lastError = $null
        break
    } catch {
        $lastError = $_
        try { if ($ws) { $ws.Dispose() } } catch { }
        $ws = $null
        if ($attempt -le $ConnRetries) {
            Say "  connection attempt $attempt/$($ConnRetries + 1) failed; retrying in ${ConnRetryDelaySeconds}s"
            Start-Sleep -Seconds $ConnRetryDelaySeconds
        }
    }
}

if (-not $ws) {
    $detail = if ($lastError) { $lastError.Exception.Message.Split([char]10)[0] } else { 'unknown error' }
    Invoke-PollFallback "websocket unreachable: $detail"
}

Say "waiting for ComfyUI job $PromptId (event-driven)"
Say "  (silence is normal. A queued, slow or apparently stuck job is still waited on.)"

$buffer = New-Object byte[] 262144
$builder = [System.Text.StringBuilder]::new()
$nodes = 0
$pending = $null

try {
    while ($ws.State -eq 'Open') {
        # Only one ReceiveAsync may be in flight. Dropping a timed-out task kills all
        # later receives (observed in practice: a job succeeded and zero events
        # arrived), so the pending task is always reused.
        if (-not $pending) {
            $segment = [ArraySegment[byte]]::new($buffer)
            $pending = $ws.ReceiveAsync($segment, [Threading.CancellationToken]::None)
        }
        $pending.Wait()
        $result = $pending.Result
        $pending = $null

        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }
        if ($result.MessageType -ne [System.Net.WebSockets.WebSocketMessageType]::Text) { continue }

        [void]$builder.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
        if (-not $result.EndOfMessage) { continue }
        $raw = $builder.ToString(); [void]$builder.Clear()

        $message = $null
        try { $message = $raw | ConvertFrom-Json } catch { continue }
        $kind = [string]$message.type
        $data = $message.data
        # Some events carry no prompt_id; only skip when present AND different.
        if ($data -and $data.prompt_id -and $data.prompt_id -ne $PromptId) { continue }

        switch ($kind) {
            'execution_start' { Say "   > started" }
            'progress' {
                if ($data.value -and $data.max -and ($data.value % [Math]::Max(1, [Math]::Floor($data.max / 5)) -eq 0)) {
                    Say "   ... $($data.value)/$($data.max)"
                }
            }
            'executed' {
                $out = if ($data.output) { $data.output } elseif ($data.outputs) { $data.outputs } else { $null }
                if ($out) { $nodes += @($out.PSObject.Properties.Name).Count }
            }
            'executing' {
                if ($null -eq $data.node) { Finish $EXIT_DONE 'DONE' "$(Elapsed)s, $nodes output node(s)" }
            }
            'execution_error' {
                $text = if ($data.exception_message) { [string]$data.exception_message } else { 'unspecified error' }
                Finish $EXIT_FAILED 'FAILED' $text
            }
            'execution_interrupted' { Finish $EXIT_FAILED 'FAILED' 'execution interrupted' }
        }
    }
} finally {
    try { if ($ws.State -eq 'Open') { $ws.CloseAsync('NormalClosure', '', [Threading.CancellationToken]::None).Wait(1500) | Out-Null } } catch { }
    try { $ws.Dispose() } catch { }
}

Invoke-PollFallback 'event stream ended'
