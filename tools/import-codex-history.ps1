# import-codex-history.ps1
# Imports prompts from OpenAI Codex CLI's history.jsonl into the corpus lake.
#
# Codex stores every prompt the user submits in ~/.codex/history.jsonl as
# JSONL: {"session_id":"019e60c1-...","ts":1780240040,"text":"the prompt"}
#
# This script reads entries newer than the persisted cursor, formats them as
# corpus entries, and appends to <CorpusRoot>/_raw-codex.md. The cursor (last
# ts imported) is stored in <CorpusRoot>/.codex-cursor.json so subsequent runs
# are incremental.
#
# Idempotent: re-running with no new Codex prompts is a no-op.

[CmdletBinding()]
param(
    [string]$CodexHistory = $(
        $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
        Join-Path $h '.codex/history.jsonl'
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

$rawFile    = Join-Path $CorpusRoot '_raw-codex.md'
$cursorFile = Join-Path $CorpusRoot '.codex-cursor.json'

if (-not (Test-Path $CodexHistory)) {
    if ($VerbosePreference -ne 'SilentlyContinue') { Write-Verbose "No Codex history at $CodexHistory" }
    exit 0
}

# Load cursor (last imported ts)
$cursorTs = 0
if (Test-Path $cursorFile) {
    try {
        $cursorTs = (Get-Content $cursorFile -Raw | ConvertFrom-Json).LastTs
    } catch { $cursorTs = 0 }
}

# Initialize raw file with header if brand new
if (-not (Test-Path $rawFile)) {
    $header = @'
# Raw Prompt Log: Codex CLI (auto-imported)

Every prompt submitted to the OpenAI Codex CLI, imported from `~/.codex/history.jsonl`.
Run by `tools/import-codex-history.ps1` (typically called from `tools/backup.ps1`
every backup cycle). Each entry tagged with its Codex session hash. Codex's
history.jsonl does not include cwd, so the source label for these entries is
"codex" (derived from the file name by curate.ps1).

---
'@
    [System.IO.File]::WriteAllText($rawFile, $header, [System.Text.UTF8Encoding]::new($false))
}

$newCount = 0
$maxTs = $cursorTs
$sha = [System.Security.Cryptography.SHA1]::Create()

$reader = [System.IO.StreamReader]::new($CodexHistory, [System.Text.UTF8Encoding]::new($false))
$buffer = New-Object System.Text.StringBuilder

try {
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if (-not $entry.ts) { continue }
        if ($entry.ts -le $cursorTs) { continue }
        if ([string]::IsNullOrWhiteSpace($entry.text)) { continue }

        $iso = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$entry.ts)).ToLocalTime().ToString('o')

        $sessionHash = 'anon'
        if ($entry.session_id) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($entry.session_id)
            $sessionHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').Substring(0,8).ToLower()
        }

        # Widen standalone "---" lines so pasted content cannot terminate the
        # entry early when curate.ps1 parses the raw markdown.
        $body = ([string]$entry.text -replace '(?m)^[ \t]*-{3}[ \t]*$', '----').Trim()
        if ([string]::IsNullOrWhiteSpace($body)) { continue }
        [void]$buffer.AppendLine()
        [void]$buffer.AppendLine("## $iso")
        [void]$buffer.AppendLine("> session: $sessionHash")
        [void]$buffer.AppendLine()
        [void]$buffer.AppendLine($body)
        [void]$buffer.AppendLine()
        [void]$buffer.AppendLine('---')

        if ($entry.ts -gt $maxTs) { $maxTs = $entry.ts }
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
    LastTs      = $maxTs
    LastRun     = (Get-Date).ToString('o')
    LastImport  = $newCount
}
[System.IO.File]::WriteAllText($cursorFile, ($cursorData | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))

if ($VerbosePreference -ne 'SilentlyContinue') {
    Write-Host "Imported $newCount new Codex entries. Cursor now at ts $maxTs."
}

exit 0
