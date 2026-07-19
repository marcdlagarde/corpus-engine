# refresh.ps1
# Refreshes the machine-readable corpus views.
#
# This is the command agents and humans should run before querying a corpus.
# It imports any new Codex CLI prompts from ~/.codex/history.jsonl and any new
# Claude Code prompts from ~/.claude/history.jsonl, then regenerates
# entries.jsonl, sessions.jsonl, curated views, and session views.

[CmdletBinding()]
param(
    [string]$CorpusRoot = $(
        if ($env:CORPUS_ROOT) { $env:CORPUS_ROOT }
        else {
            $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
            Join-Path $h 'corpus'
        }
    ),
    [switch]$SkipCodex,
    [switch]$SkipClaudeHistory,
    [switch]$Summary
)

$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path $PSCommandPath -Parent

if (-not (Test-Path $CorpusRoot)) {
    New-Item -ItemType Directory -Path $CorpusRoot -Force | Out-Null
}

if (-not $SkipCodex) {
    & (Join-Path $toolsDir 'import-codex-history.ps1') -CorpusRoot $CorpusRoot
}

if (-not $SkipClaudeHistory) {
    & (Join-Path $toolsDir 'import-claude-history.ps1') -CorpusRoot $CorpusRoot
}

$curateArgs = @{
    CorpusRoot = $CorpusRoot
}
if ($Summary) {
    $curateArgs.Summary = $true
}

& (Join-Path $toolsDir 'curate.ps1') @curateArgs

exit $LASTEXITCODE
