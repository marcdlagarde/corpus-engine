# log-prompt.ps1
# UserPromptSubmit hook for the corpus content engine.
#
# Designed to be wired into ~/.claude/settings.json so it fires in every
# Claude Code session in every project. Tags each entry with cwd + a short
# session hash for grouping.
#
# Resolves the corpus root in this order:
#   1. $env:CORPUS_ROOT (set this in your shell profile to override default)
#   2. ~/corpus (default)
#
# Reads JSON from stdin, extracts .prompt, appends to <CorpusRoot>/_RAW_PROMPT_LOG.md
# with ISO timestamp + cwd + session hash. Silent on errors. Exits 0 to
# never block prompt submission.

$ErrorActionPreference = 'SilentlyContinue'

$corpusRoot = if ($env:CORPUS_ROOT) { $env:CORPUS_ROOT } else { Join-Path $env:USERPROFILE 'corpus' }
$logFile = Join-Path $corpusRoot '_RAW_PROMPT_LOG.md'

try {
    if (-not (Test-Path $corpusRoot)) {
        New-Item -ItemType Directory -Path $corpusRoot -Force | Out-Null
    }

    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    $json = $raw | ConvertFrom-Json
    $prompt = $json.prompt
    if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }

    # cwd: prefer hook JSON payload value, fall back to process cwd.
    $cwd = if ($json.PSObject.Properties.Name -contains 'cwd' -and -not [string]::IsNullOrWhiteSpace($json.cwd)) {
        $json.cwd
    } else {
        (Get-Location).Path
    }

    # Session hash: SHA1 of session_id, first 8 hex chars. Stable per session.
    $sessionHash = 'anon'
    if ($json.PSObject.Properties.Name -contains 'session_id' -and -not [string]::IsNullOrWhiteSpace($json.session_id)) {
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json.session_id)
        $sessionHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').Substring(0,8).ToLower()
        $sha.Dispose()
    }

    $ts = (Get-Date).ToString('o')
    $entry = "`n## $ts`n> cwd: $cwd`n> session: $sessionHash`n`n$prompt`n`n---`n"

    Add-Content -LiteralPath $logFile -Value $entry -Encoding UTF8
} catch {
    # swallow - hook must not block prompt submission
}

exit 0
