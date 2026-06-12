# corpus-ask.ps1
# Ask a question of your corpus and get an answer with citations.
#
# Wraps `claude -p` (print mode) with a system prompt that points the model
# at the corpus files, grants Read/Bash/Grep access via --add-dir, and tells
# it to cite specific entry timestamps when making claims.
#
# Usage:
#   ./corpus-ask.ps1 "what are my best original metaphors?"
#   ./corpus-ask.ps1 -Model opus "compare my January and May articulation"
#   ./corpus-ask.ps1 -Trace "what files did you read?"   # see tool calls
#
# Add an alias in your $PROFILE for one-word invocation:
#   function corpus-ask { & 'D:\path\to\tools\corpus-ask.ps1' @args }
#
# Requires the `claude` CLI on PATH. Uses your Claude Pro/Max quota per query.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)]
    [string[]]$Question,

    # Default sonnet (retrieval + citation is mostly navigation). Use opus for
    # synthesis (voice analysis, articulation evolution). Use haiku for cheap
    # quick lookups.
    [ValidateSet('opus','sonnet','haiku')]
    [string]$Model = 'sonnet',

    [string]$CorpusRoot = $(if ($env:CORPUS_ROOT) { $env:CORPUS_ROOT } else { Join-Path $env:USERPROFILE 'corpus' }),

    # Trace mode: emits Claude's full event stream (stream-json) so you see
    # every tool call. Useful for confirming the model is using JSONL primary
    # sources. Named -Trace because PowerShell reserves -Verbose.
    [switch]$Trace,

    # By default, refresh entries.jsonl/sessions.jsonl before querying so the
    # answer includes newly captured Claude prompts and newly imported Codex
    # history. Use -NoRefresh only when you intentionally want the current files.
    [switch]$NoRefresh
)

$q = ($Question -join ' ').Trim()
if ([string]::IsNullOrWhiteSpace($q)) {
    Write-Host "ERROR: no question provided." -ForegroundColor Red
    Write-Host 'Usage: corpus-ask "your question here"' -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $CorpusRoot)) {
    Write-Host "ERROR: corpus root not found at $CorpusRoot" -ForegroundColor Red
    Write-Host "Run setup.ps1 first, or set `$env:CORPUS_ROOT to your corpus directory." -ForegroundColor Yellow
    exit 1
}

if (-not $NoRefresh) {
    $refreshScript = Join-Path $PSScriptRoot 'refresh.ps1'
    if (Test-Path $refreshScript) {
        & $refreshScript -CorpusRoot $CorpusRoot
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: corpus refresh failed. Query aborted so results are not stale." -ForegroundColor Red
            exit $LASTEXITCODE
        }
    } else {
        Write-Host "WARN: refresh.ps1 not found. Querying existing JSONL files, which may be stale." -ForegroundColor Yellow
    }
}

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: claude CLI not on PATH." -ForegroundColor Red
    Write-Host "Install Claude Code first: https://docs.anthropic.com/en/docs/claude-code" -ForegroundColor Yellow
    exit 1
}

# System prompt: token-tight. Forces JSONL-first navigation since the
# auto-derived markdown views (curated/, sessions/*.md, raw logs) hold the
# same data at 10-100x the token cost. Reference docs available when needed.
$systemPrompt = @"
You're a research assistant for an AI prompt corpus at $CorpusRoot.

PRIMARY data (always use these):
- sessions.jsonl: session manifest. Schema: {hash, purpose, src, cwd, first, last, count, buckets}. Safe to read in full.
- entries.jsonl: every captured prompt. Schema: {ts, sess, src, cwd, tags, len, body}. NEVER read in full. Filter via grep/Bash/Read-with-offset by sess hash, src, tags, or body keywords.

Strategy:
1. Read sessions.jsonl fully -> the map.
2. Pick relevant session hashes from purpose/src/date.
3. Filter entries.jsonl by those sess values, by tag, by src, or by body keyword. Examples:
   - grep '"sess":"a3f2b8c1"' entries.jsonl
   - grep '"src":"YourProject"' entries.jsonl | head -50
4. Read only matching lines into context.

DO NOT read (these are derived views; identical data lives in the JSONL at far lower token cost):
- curated/*.md, sessions/<hash>.md, sessions/INDEX.md, _RAW_PROMPT_LOG.md, _raw-*.md

Cite: [ts: ISO-timestamp]
Style: concise, direct, no filler. State the take, give the evidence, stop.
Caveat: corpus is prompts only, no AI responses. If the question needs the assistant's side, say so.
"@

$claudeArgs = @(
    '-p', $q,
    '--append-system-prompt', $systemPrompt,
    '--add-dir', $CorpusRoot,
    '--model', $Model
)
if ($Trace) {
    $claudeArgs += @('--output-format', 'stream-json', '--verbose')
    Write-Host "=== TRACE: stream-json events follow (one JSON per line) ===" -ForegroundColor Cyan
}

& claude @claudeArgs
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "corpus-ask could not complete through the Claude CLI." -ForegroundColor Yellow
    Write-Host "If the error above is a 401, refresh Claude Code authentication and retry." -ForegroundColor Yellow
    Write-Host "The local JSONL files were refreshed first; agents can still query entries.jsonl and sessions.jsonl directly." -ForegroundColor Yellow
}
exit $exitCode
