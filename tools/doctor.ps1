# doctor.ps1
# Preflight + diagnostic for corpus-engine.
#
# Run this any time to see: which CLIs are installed, which prompt-history
# sources exist on this machine, whether the Claude Code capture hook is
# wired, what state your corpus is in, and - for sources you don't have -
# the exact command or menu path that gets you them.
#
# Read-only: makes no changes. Safe to run before setup.ps1.

[CmdletBinding()]
param(
    [string]$CorpusRoot = $(
        if ($env:CORPUS_ROOT) { $env:CORPUS_ROOT }
        else {
            $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
            Join-Path $h 'corpus'
        }
    )
)

$ErrorActionPreference = 'SilentlyContinue'

$homeDir  = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$toolsDir = Split-Path $PSCommandPath -Parent

function Write-Check {
    param([string]$Status, [string]$Message)
    $color = switch ($Status) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'INFO' { 'Gray' }
        'MISS' { 'Yellow' }
        default { 'White' }
    }
    Write-Host ("[{0,-4}] {1}" -f $Status, $Message) -ForegroundColor $color
}

function Get-LineCount {
    param([string]$Path)
    $n = 0
    foreach ($line in [System.IO.File]::ReadLines($Path)) { $n++ }
    return $n
}

Write-Host ""
Write-Host "===== corpus-engine doctor =====" -ForegroundColor Cyan
Write-Host ""
Write-Host "Corpus root: $CorpusRoot"
Write-Host ""

# ----------------------------------------------------------------------
# 1. Environment + CLIs
# ----------------------------------------------------------------------
Write-Host "-- Environment --" -ForegroundColor Cyan
Write-Check 'OK' "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    Write-Check 'OK' "Claude Code CLI found ($($claudeCmd.Source))"
} else {
    Write-Check 'MISS' "Claude Code CLI not on PATH (needed for live capture + corpus-ask; importers work without it)"
    Write-Host "        Install (official): irm https://claude.ai/install.ps1 | iex" -ForegroundColor Gray
}

$codexCmd = Get-Command codex -ErrorAction SilentlyContinue
if ($codexCmd) {
    Write-Check 'OK' "Codex CLI found ($($codexCmd.Source))"
} else {
    Write-Check 'INFO' "Codex CLI not on PATH (optional; only needed if you want Codex history)"
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Check 'OK' "git found"
} else {
    Write-Check 'INFO' "git not found (only needed for the optional private-repo backup)"
    Write-Host "        Install: winget install --id Git.Git -e" -ForegroundColor Gray
}

# ----------------------------------------------------------------------
# 2. Local history sources (free backfill - already on this machine)
# ----------------------------------------------------------------------
Write-Host ""
Write-Host "-- Local history sources --" -ForegroundColor Cyan

$codexHistory = Join-Path $homeDir '.codex/history.jsonl'
if (Test-Path $codexHistory) {
    Write-Check 'OK' "Codex CLI history: $(Get-LineCount $codexHistory) prompts ($codexHistory)"
    Write-Host "        Imported automatically by refresh.ps1." -ForegroundColor Gray
} else {
    Write-Check 'INFO' "No Codex CLI history ($codexHistory)"
}

$claudeHistory = Join-Path $homeDir '.claude/history.jsonl'
if (Test-Path $claudeHistory) {
    Write-Check 'OK' "Claude Code history: $(Get-LineCount $claudeHistory) prompts ($claudeHistory)"
    Write-Host "        Imported automatically by refresh.ps1 (deduped against the live hook)." -ForegroundColor Gray
} else {
    Write-Check 'INFO' "No Claude Code history ($claudeHistory)"
}

$settingsPath = Join-Path $homeDir '.claude/settings.json'
$hookWired = $false
if (Test-Path $settingsPath) {
    $settingsRaw = Get-Content $settingsPath -Raw
    if ($settingsRaw -match 'log-prompt\.ps1') { $hookWired = $true }
}
if ($hookWired) {
    Write-Check 'OK' "Claude Code capture hook is wired in ~/.claude/settings.json"
} elseif ($claudeCmd) {
    Write-Check 'MISS' "Claude Code capture hook not wired (live capture inactive)"
    Write-Host "        Run setup.ps1 - it prints the exact JSON snippet for ~/.claude/settings.json." -ForegroundColor Gray
} else {
    Write-Check 'INFO' "Claude Code capture hook: n/a (CLI not installed)"
}

# ----------------------------------------------------------------------
# 3. Export-based sources (ChatGPT / Claude.ai / Gemini)
# ----------------------------------------------------------------------
Write-Host ""
Write-Host "-- Export-based sources (for ChatGPT / Claude Desktop / Gemini users) --" -ForegroundColor Cyan

$foundExports = @()
$downloads = Join-Path $homeDir 'Downloads'
if (Test-Path $downloads) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zips = Get-ChildItem -Path $downloads -Filter '*.zip' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 15
    foreach ($z in $zips) {
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($z.FullName)
            $names = @($zip.Entries | ForEach-Object { $_.Name })
            $fullNames = @($zip.Entries | ForEach-Object { $_.FullName })
            if ($names -contains 'conversations.json') {
                if ($names -contains 'chat.html') {
                    $foundExports += [PSCustomObject]@{ Kind = 'ChatGPT export'; Path = $z.FullName; Tool = 'import-chatgpt-export.ps1' }
                } elseif (($names -contains 'users.json') -or ($names -contains 'projects.json')) {
                    $foundExports += [PSCustomObject]@{ Kind = 'Claude.ai export'; Path = $z.FullName; Tool = 'import-claude-export.ps1' }
                } else {
                    $foundExports += [PSCustomObject]@{ Kind = 'ChatGPT or Claude.ai export'; Path = $z.FullName; Tool = 'import-chatgpt-export.ps1 (or import-claude-export.ps1)' }
                }
            } elseif ($fullNames | Where-Object { $_ -match 'Gemini' -and $_ -match 'MyActivity\.(json|html)$' }) {
                $foundExports += [PSCustomObject]@{ Kind = 'Google Takeout (Gemini)'; Path = $z.FullName; Tool = 'import-gemini-takeout.ps1' }
            }
        } catch {
        } finally {
            if ($zip) { $zip.Dispose() }
        }
    }
}

if ($foundExports.Count -gt 0) {
    foreach ($fe in $foundExports) {
        Write-Check 'OK' "Found $($fe.Kind): $($fe.Path)"
        # Escape quotes: filenames are attacker-controllable (anything can land
        # in Downloads) and users copy-paste this suggested command.
        $safeTool = (Join-Path $toolsDir $fe.Tool) -replace "'", "''"
        $safePath = $fe.Path -replace "'", "''"
        Write-Host "        Import: & '$safeTool' -ExportPath '$safePath'" -ForegroundColor Gray
    }
} else {
    Write-Check 'INFO' "No export zips detected in $downloads (scanned newest 15 zips)"
}

Write-Host ""
Write-Host "  How to get exports you don't have yet:" -ForegroundColor Gray
Write-Host "   ChatGPT (Desktop/web/mobile): Settings -> Data Controls -> Export data (zip arrives by email)" -ForegroundColor Gray
Write-Host "   Claude Desktop / claude.ai:   Settings -> Privacy -> Export data (link arrives by email)" -ForegroundColor Gray
Write-Host "   Gemini: takeout.google.com -> My Activity -> 'Gemini Apps' only -> format JSON" -ForegroundColor Gray
Write-Host "     (Work/Workspace accounts may have Takeout disabled by the admin; if 'Gemini Apps" -ForegroundColor Gray
Write-Host "      Activity' was off, there is no history to export.)" -ForegroundColor Gray

# ----------------------------------------------------------------------
# 4. Corpus state
# ----------------------------------------------------------------------
Write-Host ""
Write-Host "-- Corpus state --" -ForegroundColor Cyan

if (-not (Test-Path $CorpusRoot)) {
    Write-Check 'MISS' "Corpus root does not exist yet - run setup.ps1"
} else {
    Write-Check 'OK' "Corpus root exists"

    $hookLog = Join-Path $CorpusRoot '_RAW_PROMPT_LOG.md'
    if (Test-Path $hookLog) {
        Write-Check 'OK' "Live hook capture: _RAW_PROMPT_LOG.md ($([math]::Round((Get-Item $hookLog).Length / 1KB, 1)) KB)"
    } else {
        Write-Check 'INFO' "No _RAW_PROMPT_LOG.md yet (appears after the first hooked Claude Code prompt)"
    }

    $rawImports = Get-ChildItem -Path $CorpusRoot -Filter '_raw-*.md' -File -ErrorAction SilentlyContinue
    foreach ($ri in $rawImports) {
        Write-Check 'OK' "Imported source: $($ri.Name) ($([math]::Round($ri.Length / 1KB, 1)) KB)"
    }

    $entriesJsonl = Join-Path $CorpusRoot 'entries.jsonl'
    if (Test-Path $entriesJsonl) {
        Write-Check 'OK' "entries.jsonl: $(Get-LineCount $entriesJsonl) entries"
    } else {
        Write-Check 'INFO' "No entries.jsonl yet - run refresh.ps1 after importing"
    }

    $manifest = Join-Path $CorpusRoot 'curated/_manifest.json'
    if (Test-Path $manifest) {
        $lastRun = (Get-Content $manifest -Raw | ConvertFrom-Json).LastRun
        Write-Check 'INFO' "Last curation run: $lastRun"
    }

    # Backup remote: the corpus is the user's complete prompt history, so a
    # public remote is effectively publication.
    if ((Test-Path (Join-Path $CorpusRoot '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $origin = git -C $CorpusRoot remote get-url origin 2>$null
        if ($origin) {
            Write-Check 'INFO' "Backup remote: $origin - receives your FULL corpus; it must be PRIVATE"
            if (Get-Command gh -ErrorAction SilentlyContinue) {
                $visibility = ''
                Push-Location $CorpusRoot
                try { $visibility = (& gh repo view --json visibility --jq '.visibility' 2>$null) } catch {}
                Pop-Location
                if ("$visibility" -match '(?i)public') {
                    Write-Check 'WARN' "Backup remote is PUBLIC. Make it private now - backup.ps1 will refuse to push until then."
                } elseif ("$visibility" -match '(?i)private') {
                    Write-Check 'OK' "Backup remote visibility: private"
                }
            }
        } else {
            Write-Check 'INFO' "Corpus git repo has no remote (backups stay local-only)"
        }
    }
}

Write-Host ""
Write-Host "Done. Nothing was modified." -ForegroundColor Green
Write-Host ""
exit 0
