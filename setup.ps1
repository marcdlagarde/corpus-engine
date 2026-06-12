# setup.ps1
# One-time install for corpus-engine on Windows.
#
# Creates your corpus directory, runs a curation pass against the bundled
# samples so you can see the engine produce real output before capturing
# anything of your own, and prints the manual steps for hooking up Claude
# Code and the optional auto-backup.
#
# Does NOT auto-modify ~/.claude/settings.json or register scheduled tasks.
# Those are opt-in; this script prints the snippets you need.

[CmdletBinding()]
param(
    [string]$CorpusRoot = $(if ($env:CORPUS_ROOT) { $env:CORPUS_ROOT } else { Join-Path $env:USERPROFILE 'corpus' })
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSCommandPath -Parent
$toolsDir = Join-Path $repoRoot 'tools'
$templatesDir = Join-Path $repoRoot 'templates'

Write-Host ""
Write-Host "===== corpus-engine setup =====" -ForegroundColor Cyan
Write-Host ""
Write-Host "Repo:        $repoRoot"
Write-Host "Corpus root: $CorpusRoot"
Write-Host ""

# Prereq checks
$ok = $true

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "[FAIL] PowerShell 5.1+ required. You have $($PSVersionTable.PSVersion)." -ForegroundColor Red
    $ok = $false
} else {
    Write-Host "[ OK ] PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green
}

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host "[ OK ] Claude Code CLI found ($((Get-Command claude).Source))" -ForegroundColor Green
} else {
    Write-Host "[WARN] Claude Code CLI not found on PATH." -ForegroundColor Yellow
    Write-Host "       The capture hook and corpus-ask won't work without it." -ForegroundColor Yellow
    Write-Host "       Install: https://docs.anthropic.com/en/docs/claude-code" -ForegroundColor Yellow
}

if (Test-Path (Join-Path $env:USERPROFILE '.codex\history.jsonl')) {
    $codexSize = (Get-Item (Join-Path $env:USERPROFILE '.codex\history.jsonl')).Length / 1KB
    Write-Host "[ OK ] Codex CLI history found ($([math]::Round($codexSize, 1)) KB)" -ForegroundColor Green
} else {
    Write-Host "[INFO] No Codex CLI history.jsonl found. That's fine - Codex import is optional." -ForegroundColor Gray
}

if (-not $ok) {
    Write-Host ""
    Write-Host "Prereq check failed. Fix the errors above and re-run." -ForegroundColor Red
    exit 1
}

# Create corpus root
if (-not (Test-Path $CorpusRoot)) {
    New-Item -ItemType Directory -Path $CorpusRoot -Force | Out-Null
    Write-Host "[ OK ] Created corpus root at $CorpusRoot" -ForegroundColor Green
} else {
    Write-Host "[ OK ] Corpus root already exists at $CorpusRoot" -ForegroundColor Green
}

# Install corpus-local agent instructions so future Claude/Codex sessions know
# how to refresh and query entries.jsonl without rediscovering the engine.
$agentTemplate = Join-Path $templatesDir 'AGENTS.md'
$agentTarget = Join-Path $CorpusRoot 'AGENTS.md'
if ((Test-Path $agentTemplate) -and -not (Test-Path $agentTarget)) {
    $agentText = Get-Content $agentTemplate -Raw
    $agentText = $agentText.Replace('{{CORPUS_ROOT}}', $CorpusRoot).Replace('{{TOOLS_DIR}}', $toolsDir)
    [System.IO.File]::WriteAllText($agentTarget, $agentText, [System.Text.UTF8Encoding]::new($false))
    Write-Host "[ OK ] Installed corpus agent instructions at $agentTarget" -ForegroundColor Green
} elseif (Test-Path $agentTarget) {
    Write-Host "[INFO] Corpus agent instructions already exist at $agentTarget" -ForegroundColor Gray
}

# Run a curation pass against the bundled samples so the user sees the engine work
$sampleSrc = Join-Path $repoRoot 'samples'
if (Test-Path $sampleSrc) {
    Write-Host ""
    Write-Host "Running curation against bundled samples to demonstrate the pipeline..." -ForegroundColor Cyan
    & (Join-Path $toolsDir 'curate.ps1') -CorpusRoot $sampleSrc -Summary
}

Write-Host ""
Write-Host "===== Next steps (manual) =====" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. WIRE THE CLAUDE CODE CAPTURE HOOK" -ForegroundColor Yellow
Write-Host "   Add this to your ~/.claude/settings.json under the 'hooks' key:"
Write-Host ""
# Generate JSON programmatically so quotes and Windows backslashes are escaped properly
$hookObj = [ordered]@{
    hooks = [ordered]@{
        UserPromptSubmit = @(
            [ordered]@{
                hooks = @(
                    [ordered]@{
                        type    = 'command'
                        command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $toolsDir 'log-prompt.ps1')`""
                        timeout = 5
                    }
                )
            }
        )
    }
}
$hookSnippet = ($hookObj | ConvertTo-Json -Depth 10) -split "`r?`n" | ForEach-Object { "   $_" } | Out-String
Write-Host $hookSnippet -ForegroundColor Gray
Write-Host ""
Write-Host "   In Claude Code, type /hooks once after editing to reload."
Write-Host ""
Write-Host "2. REFRESH YOUR CORPUS EXPORTS" -ForegroundColor Yellow
Write-Host "   This imports Codex history if present and regenerates entries.jsonl/sessions.jsonl:"
Write-Host "     & '$toolsDir\refresh.ps1' -CorpusRoot '$CorpusRoot' -Summary"
Write-Host ""
Write-Host "3. ASK YOUR CORPUS QUESTIONS" -ForegroundColor Yellow
Write-Host "   & '$toolsDir\corpus-ask.ps1' `"what are my recurring themes?`""
Write-Host ""
Write-Host "4. OPTIONAL: AUTO-BACKUP EVERY 30 MIN" -ForegroundColor Yellow
Write-Host "   Initialize git in your corpus, then from an ELEVATED PowerShell:"
Write-Host "     & '$toolsDir\setup-backup-task.ps1'"
Write-Host ""
Write-Host "Set `$env:CORPUS_ROOT in your `$PROFILE to skip the -CorpusRoot argument:" -ForegroundColor Cyan
Write-Host "   `$env:CORPUS_ROOT = '$CorpusRoot'"
Write-Host ""
Write-Host "Done. Open '$CorpusRoot' in your editor and you're ready." -ForegroundColor Green
Write-Host ""
