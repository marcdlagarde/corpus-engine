# install.ps1
# One-line bootstrap for corpus-engine on Windows:
#
#   irm https://raw.githubusercontent.com/marcdlagarde/corpus-engine/main/install.ps1 | iex
#
# What it does (and nothing else):
#   1. Gets the repo to ~\corpus-engine (git clone if git is available,
#      otherwise downloads the GitHub zip - no git required)
#   2. Runs setup.ps1 (creates your corpus dir, demos the pipeline,
#      prints the manual opt-in steps)
#   3. Runs tools\doctor.ps1 (shows which prompt-history sources exist on
#      this machine and how to get the ones that don't)
#
# It does NOT install the Claude or Codex CLIs, does not modify
# ~/.claude/settings.json, does not register scheduled tasks, and does not
# touch anything outside ~\corpus-engine and your corpus root. Anything
# beyond that is printed as a manual step for you to review.
#
# Override the install location with $env:CORPUS_ENGINE_HOME before running.
# Pin to a release tag (recommended once tags exist) with $env:CORPUS_ENGINE_REF,
# e.g. $env:CORPUS_ENGINE_REF = 'v0.2' - installing a tag instead of moving
# `main` means a later repo compromise cannot change what this line installs.

$ErrorActionPreference = 'Stop'

$repoUrl  = 'https://github.com/marcdlagarde/corpus-engine'
$ref      = if ($env:CORPUS_ENGINE_REF) { $env:CORPUS_ENGINE_REF } else { 'main' }
$homeDir  = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$dest     = if ($env:CORPUS_ENGINE_HOME) { $env:CORPUS_ENGINE_HOME } else { Join-Path $homeDir 'corpus-engine' }

Write-Host ""
Write-Host "===== corpus-engine bootstrap =====" -ForegroundColor Cyan
Write-Host "Install location: $dest"
Write-Host ""

# PS 5.1 defaults to TLS 1.0 for web requests; GitHub requires 1.2+
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$haveGit = [bool](Get-Command git -ErrorAction SilentlyContinue)

if (Test-Path (Join-Path $dest '.git')) {
    if ($haveGit) {
        Write-Host "Existing clone found - updating..." -ForegroundColor Cyan
        git -C $dest pull --ff-only
    } else {
        Write-Host "Existing clone found at $dest (git not available to update it - continuing as-is)." -ForegroundColor Yellow
    }
} elseif (Test-Path (Join-Path $dest 'setup.ps1')) {
    Write-Host "Existing install found at $dest (not a git clone - continuing as-is)." -ForegroundColor Yellow
} elseif (Test-Path $dest) {
    Write-Host "$dest exists but does not look like corpus-engine. Move it aside or set" -ForegroundColor Red
    Write-Host "`$env:CORPUS_ENGINE_HOME to a different location, then re-run." -ForegroundColor Red
    exit 1
} else {
    if ($haveGit) {
        Write-Host "Cloning $repoUrl (ref: $ref) ..." -ForegroundColor Cyan
        git clone --branch $ref $repoUrl $dest
    } else {
        Write-Host "git not found - downloading zip from GitHub instead (git is only needed for updates and the optional backup)." -ForegroundColor Yellow
        $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "corpus-engine-$([guid]::NewGuid().ToString('n')).zip"
        # archive/<ref>.zip resolves branches and tags alike
        Invoke-WebRequest -Uri "$repoUrl/archive/$ref.zip" -OutFile $zipPath -UseBasicParsing
        $stage = Join-Path ([System.IO.Path]::GetTempPath()) "corpus-engine-stage-$([guid]::NewGuid().ToString('n'))"
        Expand-Archive -Path $zipPath -DestinationPath $stage
        $extracted = Get-ChildItem -Path $stage -Directory | Select-Object -First 1
        Move-Item -Path $extracted.FullName -Destination $dest
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path (Join-Path $dest 'setup.ps1'))) {
    Write-Host "Install failed: $dest\setup.ps1 not found." -ForegroundColor Red
    exit 1
}

Write-Host ""
& (Join-Path $dest 'setup.ps1')

Write-Host ""
& (Join-Path $dest 'tools\doctor.ps1')
