# import-gemini-takeout.ps1
# Imports YOUR prompts from a Google Takeout export of Gemini activity.
#
# Gemini (web and app) keeps no local history file. The supported path is
# Google Takeout (https://takeout.google.com):
#   1. Deselect all, then select "My Activity"
#   2. Under "All activity data included" pick ONLY "Gemini Apps"
#   3. Under "Multiple formats" set Activity records to JSON (default is HTML)
#   4. Export, download the zip
#
# Caveats (documented, not fixable here):
#   - Work/Workspace accounts: the admin may have Takeout disabled entirely.
#   - If "Gemini Apps Activity" was turned off, there is no history to export.
#   - Takeout only includes prompts, and only if activity saving was on.
#   - The standalone "Gemini" Takeout product exports Gems, NOT chat history;
#     it must be "My Activity" -> "Gemini Apps".
#
# Usage:
#   .\import-gemini-takeout.ps1 -ExportPath ~\Downloads\takeout-2026....zip
#
# -ExportPath accepts the Takeout zip, an extracted folder, or MyActivity.json
# directly. The zip is read in-memory (never extracted to disk).
#
# Gemini activity has no session/conversation ids, so entries are grouped into
# one synthetic session per calendar day.
#
# Regenerates <CorpusRoot>/_raw-gemini.md from scratch each run. Takeout
# exports are full-history snapshots, so re-importing a newer export simply
# replaces the file. Idempotent for a given export.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExportPath,
    [string]$CorpusRoot = $(
        if ($env:CORPUS_ROOT) { $env:CORPUS_ROOT }
        else {
            $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
            Join-Path $h 'corpus'
        }
    )
)

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path $PSCommandPath -Parent) 'import-export-common.ps1')

$jsonText = Get-ExportJsonText -Path $ExportPath -CandidateNames @('MyActivity.json') -EntryPathPattern 'Gemini'
if (-not $jsonText) {
    # Detect the classic mistake: HTML-format Takeout instead of JSON
    $htmlText = Get-ExportJsonText -Path $ExportPath -CandidateNames @('MyActivity.html') -EntryPathPattern 'Gemini'
    if ($htmlText) {
        Write-Host "Found MyActivity.html - your Takeout was exported in HTML format." -ForegroundColor Red
        Write-Host "Re-export with Activity records set to JSON (Takeout -> My Activity -> Multiple formats)." -ForegroundColor Yellow
    } else {
        Write-Host "Could not find a Gemini MyActivity.json in '$ExportPath'." -ForegroundColor Red
        Write-Host "Export via takeout.google.com: My Activity -> filter to 'Gemini Apps' -> format JSON." -ForegroundColor Yellow
        Write-Host "Note: the standalone 'Gemini' Takeout product exports Gems, not chat history." -ForegroundColor Yellow
    }
    exit 1
}

Write-Host "Parsing MyActivity.json ($([math]::Round($jsonText.Length / 1MB, 1)) MB)..."
$activities = ConvertFrom-JsonPortable -Text $jsonText
$jsonText = $null

if (-not $activities -or $activities.Count -eq 0) {
    Write-Host "MyActivity.json parsed but contained no activity records." -ForegroundColor Yellow
    exit 1
}

$sha = [System.Security.Cryptography.SHA1]::Create()
$entries = New-Object System.Collections.ArrayList
$skippedNonPrompt = 0

foreach ($act in $activities) {
    if (-not ($act -is [System.Collections.IDictionary])) { continue }
    if (-not $act.ContainsKey('title') -or -not $act['title']) { continue }

    # Prompts are recorded as title "Prompted <text>". Other records
    # ("Used Gemini Apps", image generations, etc.) are not prompts.
    # NOTE: assumes an English-locale Google account; localized accounts
    # use a translated prefix.
    $title = [string]$act['title']
    if ($title -notmatch '^Prompted\s+(?s)(.+)$') { $skippedNonPrompt++; continue }
    $body = Protect-EntryBody -Text $Matches[1]
    if ([string]::IsNullOrWhiteSpace($body)) { continue }

    if (-not $act.ContainsKey('time') -or -not $act['time']) { continue }
    try { $dto = [DateTimeOffset]::Parse([string]$act['time']).ToLocalTime() } catch { continue }

    # Synthetic per-day session (Takeout has no conversation ids)
    $dayKey = 'gemini-' + $dto.ToString('yyyy-MM-dd')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($dayKey)
    $sessionHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').Substring(0,8).ToLower()

    [void]$entries.Add([PSCustomObject]@{ Ts = $dto.ToString('o'); Session = $sessionHash; Body = $body })
}
$sha.Dispose()

if ($entries.Count -eq 0) {
    Write-Host "Parsed $($activities.Count) activity records but found no 'Prompted ...' entries." -ForegroundColor Yellow
    Write-Host "If your Google account language is not English, the prompt prefix is localized;" -ForegroundColor Yellow
    Write-Host "open the file and adjust the '^Prompted' regex in this script to match." -ForegroundColor Yellow
    exit 1
}

$rawFile = Join-Path $CorpusRoot '_raw-gemini.md'
if (-not (Test-Path $CorpusRoot)) { New-Item -ItemType Directory -Path $CorpusRoot -Force | Out-Null }

$header = @"
# Raw Prompt Log: Gemini (imported from Google Takeout)

Your Gemini prompts from a Google Takeout export of My Activity -> Gemini Apps.
Gemini responses are not included in Takeout activity records. Sessions are
synthetic (one per calendar day) because Takeout has no conversation ids.
Regenerated from scratch by ``tools/import-gemini-takeout.ps1`` on each import;
re-import a newer export to replace this file.

Source export: $ExportPath
Imported: $((Get-Date).ToString('o'))
Prompts: $($entries.Count) (skipped $skippedNonPrompt non-prompt activity records)

---
"@

$buffer = New-Object System.Text.StringBuilder
[void]$buffer.Append($header)
foreach ($e in ($entries | Sort-Object Ts)) {
    [void]$buffer.AppendLine()
    [void]$buffer.AppendLine("## $($e.Ts)")
    [void]$buffer.AppendLine("> session: $($e.Session)")
    [void]$buffer.AppendLine()
    [void]$buffer.AppendLine($e.Body)
    [void]$buffer.AppendLine()
    [void]$buffer.AppendLine('---')
}
[System.IO.File]::WriteAllText($rawFile, $buffer.ToString(), [System.Text.UTF8Encoding]::new($false))

Write-Host "Imported $($entries.Count) Gemini prompts into $rawFile" -ForegroundColor Green
Write-Host "Run refresh.ps1 to fold them into entries.jsonl / sessions.jsonl." -ForegroundColor Cyan
Write-Host "The Takeout zip contains your full activity - store it somewhere private or delete it after import." -ForegroundColor Yellow

exit 0
