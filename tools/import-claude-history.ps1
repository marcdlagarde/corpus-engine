# import-claude-history.ps1
# Imports prompts from Claude Code's own history file into the corpus lake.
#
# Claude Code stores every prompt you submit in ~/.claude/history.jsonl as
# JSONL: {"display":"the prompt","pastedContents":{},"timestamp":1768447350372,
#         "project":"D:\\some\\cwd","sessionId":"uuid"}
#
# This backfills your ENTIRE Claude Code history on day one - no need to wait
# for the UserPromptSubmit hook to accumulate captures. The hook remains the
# richer live source (it captures pasted content in full; history.jsonl only
# stores a "[Pasted text ...]" placeholder in display).
#
# Dedupe: prompts already captured by the hook in _RAW_PROMPT_LOG.md are
# skipped, matched by (session hash + exact body) OR (session hash + timestamp
# within 5 seconds). Both files record the same submission instant, so the
# window catches paste-placeholder mismatches.
#
# Incremental via <CorpusRoot>/.claude-history-cursor.json (last imported
# timestamp, ms epoch). Idempotent: re-running with no new prompts is a no-op.

[CmdletBinding()]
param(
    [string]$ClaudeHistory = $(
        $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
        Join-Path $h '.claude/history.jsonl'
    ),
    [string]$CorpusRoot = $(
        if ($env:CORPUS_ROOT) { $env:CORPUS_ROOT }
        else {
            $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
            Join-Path $h 'corpus'
        }
    )
)

$ErrorActionPreference = 'SilentlyContinue'

if (-not (Test-Path $CorpusRoot)) {
    New-Item -ItemType Directory -Path $CorpusRoot -Force | Out-Null
}

$rawFile    = Join-Path $CorpusRoot '_raw-claude-code.md'
$hookFile   = Join-Path $CorpusRoot '_RAW_PROMPT_LOG.md'
$cursorFile = Join-Path $CorpusRoot '.claude-history-cursor.json'

if (-not (Test-Path $ClaudeHistory)) {
    if ($VerbosePreference -ne 'SilentlyContinue') { Write-Verbose "No Claude Code history at $ClaudeHistory" }
    exit 0
}

# Load cursor (last imported timestamp, ms epoch)
$cursorTs = [int64]0
if (Test-Path $cursorFile) {
    try {
        $cursorTs = [int64](Get-Content $cursorFile -Raw | ConvertFrom-Json).LastTs
    } catch { $cursorTs = 0 }
}

# Build dedupe sets from the hook capture file, if present.
# Key 1: "<sessionHash>|<trimmed body>"  Key 2: per-session submission times.
$seenBodies = New-Object 'System.Collections.Generic.HashSet[string]'
$sessTimes  = @{}
if (Test-Path $hookFile) {
    $hookContent = Get-Content $hookFile -Raw
    if (-not [string]::IsNullOrWhiteSpace($hookContent)) {
        $parsed = [regex]::Matches($hookContent,
            '(?ms)^## (\S+)(?:\r?\n> cwd: ([^\r\n]+))?(?:\r?\n> session: ([^\r\n]+))?\r?\n\r?\n(.+?)(?=\r?\n\r?\n---[ \t]*\r?$|\z)')
        foreach ($m in $parsed) {
            $sess = if ($m.Groups[3].Success) { $m.Groups[3].Value.Trim() } else { 'anon' }
            [void]$seenBodies.Add("$sess|$($m.Groups[4].Value.Trim())")
            try {
                $dto = [DateTimeOffset]::Parse($m.Groups[1].Value)
                if (-not $sessTimes.ContainsKey($sess)) { $sessTimes[$sess] = New-Object 'System.Collections.Generic.List[DateTimeOffset]' }
                $sessTimes[$sess].Add($dto)
            } catch {}
        }
    }
}

# Initialize raw file with header if brand new
if (-not (Test-Path $rawFile)) {
    $header = @'
# Raw Prompt Log: Claude Code history (auto-imported)

Every prompt submitted to Claude Code, imported from `~/.claude/history.jsonl`.
Run by `tools/import-claude-history.ps1` (typically called from `tools/refresh.ps1`).
Entries already captured live by the UserPromptSubmit hook are deduplicated.
Pasted content appears as a "[Pasted text ...]" placeholder; the hook capture
in _RAW_PROMPT_LOG.md holds the full text for prompts submitted after the hook
was installed.

---
'@
    [System.IO.File]::WriteAllText($rawFile, $header, [System.Text.UTF8Encoding]::new($false))
}

$newCount = 0
$dupCount = 0
$maxTs = $cursorTs
$sha = [System.Security.Cryptography.SHA1]::Create()

$reader = [System.IO.StreamReader]::new($ClaudeHistory, [System.Text.UTF8Encoding]::new($false))
$buffer = New-Object System.Text.StringBuilder

try {
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if (-not $entry.timestamp) { continue }
        $ts = [int64]$entry.timestamp
        if ($ts -le $cursorTs) { continue }
        if ([string]::IsNullOrWhiteSpace($entry.display)) { continue }

        # Same hash the hook computes: SHA1 of sessionId, first 8 hex chars.
        $sessionHash = 'anon'
        if ($entry.sessionId) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$entry.sessionId)
            $sessionHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').Substring(0,8).ToLower()
        }

        $dto = [DateTimeOffset]::FromUnixTimeMilliseconds($ts).ToLocalTime()

        # A line of only dashes inside a body would terminate the entry early
        # when curate.ps1 parses the raw markdown; widen to four dashes.
        $body = ([string]$entry.display -replace '(?m)^[ \t]*-{3}[ \t]*$', '----').Trim()
        if ([string]::IsNullOrWhiteSpace($body)) { continue }

        # Dedupe against hook captures
        $isDup = $seenBodies.Contains("$sessionHash|$body")
        if (-not $isDup -and $sessTimes.ContainsKey($sessionHash)) {
            foreach ($t in $sessTimes[$sessionHash]) {
                if ([math]::Abs(($t - $dto).TotalSeconds) -le 5) { $isDup = $true; break }
            }
        }
        if ($isDup) {
            $dupCount++
            if ($ts -gt $maxTs) { $maxTs = $ts }
            continue
        }

        $iso = $dto.ToString('o')
        [void]$buffer.AppendLine()
        [void]$buffer.AppendLine("## $iso")
        if (-not [string]::IsNullOrWhiteSpace($entry.project)) {
            [void]$buffer.AppendLine("> cwd: $($entry.project)")
        }
        [void]$buffer.AppendLine("> session: $sessionHash")
        [void]$buffer.AppendLine()
        [void]$buffer.AppendLine($body)
        [void]$buffer.AppendLine()
        [void]$buffer.AppendLine('---')

        if ($ts -gt $maxTs) { $maxTs = $ts }
        $newCount++
    }
} finally {
    $reader.Dispose()
    $sha.Dispose()
}

if ($newCount -gt 0) {
    [System.IO.File]::AppendAllText($rawFile, $buffer.ToString(), [System.Text.UTF8Encoding]::new($false))
}

$cursorData = [ordered]@{
    LastTs     = $maxTs
    LastRun    = (Get-Date).ToString('o')
    LastImport = $newCount
    LastDupes  = $dupCount
}
[System.IO.File]::WriteAllText($cursorFile, ($cursorData | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))

if ($VerbosePreference -ne 'SilentlyContinue') {
    Write-Host "Imported $newCount new Claude Code entries ($dupCount deduped against hook capture). Cursor now at ts $maxTs."
}

exit 0
