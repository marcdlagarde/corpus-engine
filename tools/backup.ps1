# backup.ps1
# Optional: auto-backup the corpus to your own private GitHub repo.
#
# This file is opt-in. The engine works fine without it; this just runs the
# Codex importer + curation + commits + pushes whatever changed.
#
# Set up:
#   1. Inside your corpus root, run: git init && git remote add origin <your-private-repo>
#   2. Run setup-backup-task.ps1 (elevated) to register the 30-min scheduled task.
#
# Then this script runs every 30 minutes automatically. Safe to run by hand too.

$ErrorActionPreference = 'SilentlyContinue'

$corpusRoot = if ($env:CORPUS_ROOT) { $env:CORPUS_ROOT } else { Join-Path $env:USERPROFILE 'corpus' }
$toolsDir = Split-Path $PSCommandPath -Parent

if (-not (Test-Path $corpusRoot)) {
    Write-Host "Corpus root not found at $corpusRoot. Skipping backup."
    exit 0
}

# 1. Sync Codex prompts and refresh curated/JSONL views
& (Join-Path $toolsDir 'refresh.ps1') -CorpusRoot $corpusRoot

# 2. Commit + push (only if a git remote is configured)
Set-Location $corpusRoot
if (-not (Test-Path '.git')) {
    # No git repo set up; skip the commit step entirely
    exit 0
}

$hasRemote = $false
try { if (git remote 2>$null) { $hasRemote = $true } } catch {}

git add -A
if (git status --porcelain) {
    git commit -m "auto-backup $(Get-Date -Format s)" | Out-Null
}
if ($hasRemote) {
    git push 2>$null | Out-Null
}
