# import-claude-export.ps1
# Imports YOUR prompts from a claude.ai data export into the corpus lake.
#
# Claude Desktop and claude.ai share one server-side history; there is no
# readable local transcript file. The supported path is the official export:
#   claude.ai -> Settings -> Privacy -> Export data
# Anthropic emails a link to a zip containing conversations.json (complete
# history, all tiers including free).
#
# Usage:
#   .\import-claude-export.ps1 -ExportPath ~\Downloads\claude-export.zip
#   .\import-claude-export.ps1 -ExportPath ~\Downloads\conversations.json
#
# -ExportPath accepts the zip itself, an extracted conversations.json, or a
# directory containing one. The zip is read in-memory (never extracted to
# disk). Only messages with sender "human" are imported.
#
# Regenerates <CorpusRoot>/_raw-claude-ai.md from scratch each run. Exports
# are always full-history snapshots, so re-importing a newer export simply
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

$jsonText = Get-ExportJsonText -Path $ExportPath -CandidateNames @('conversations.json')
if (-not $jsonText) {
    Write-Host "Could not find conversations.json in '$ExportPath'." -ForegroundColor Red
    Write-Host "Point -ExportPath at the export zip from claude.ai Settings -> Privacy -> Export data," -ForegroundColor Yellow
    Write-Host "or at an extracted conversations.json." -ForegroundColor Yellow
    exit 1
}

Write-Host "Parsing conversations.json ($([math]::Round($jsonText.Length / 1MB, 1)) MB)..."
$conversations = ConvertFrom-JsonPortable -Text $jsonText
$jsonText = $null

if (-not $conversations -or $conversations.Count -eq 0) {
    Write-Host "conversations.json parsed but contained no conversations." -ForegroundColor Yellow
    exit 1
}

$sha = [System.Security.Cryptography.SHA1]::Create()
$entries = New-Object System.Collections.ArrayList
$convCount = 0

foreach ($conv in $conversations) {
    if (-not ($conv -is [System.Collections.IDictionary])) { continue }
    $convCount++

    $convId = $null
    foreach ($k in @('uuid', 'id', 'name')) {
        if ($conv.ContainsKey($k) -and $conv[$k]) { $convId = [string]$conv[$k]; break }
    }
    if (-not $convId) { $convId = "claude-ai-$convCount" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($convId)
    $sessionHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').Substring(0,8).ToLower()

    $convCreated = if ($conv.ContainsKey('created_at')) { [string]$conv['created_at'] } else { $null }

    if (-not $conv.ContainsKey('chat_messages')) { continue }

    foreach ($msg in @($conv['chat_messages'])) {
        if (-not ($msg -is [System.Collections.IDictionary])) { continue }
        if (-not $msg.ContainsKey('sender') -or [string]$msg['sender'] -ne 'human') { continue }

        # Prefer the structured content array; fall back to the flat text field.
        $textParts = New-Object System.Collections.ArrayList
        if ($msg.ContainsKey('content') -and $msg['content']) {
            foreach ($block in @($msg['content'])) {
                if (($block -is [System.Collections.IDictionary]) -and
                    $block.ContainsKey('type') -and [string]$block['type'] -eq 'text' -and
                    $block.ContainsKey('text') -and $block['text']) {
                    [void]$textParts.Add([string]$block['text'])
                }
            }
        }
        if ($textParts.Count -eq 0 -and $msg.ContainsKey('text') -and $msg['text']) {
            [void]$textParts.Add([string]$msg['text'])
        }
        if ($textParts.Count -eq 0) { continue }

        $body = Protect-EntryBody -Text ($textParts -join "`n")
        if ([string]::IsNullOrWhiteSpace($body)) { continue }

        $tsRaw = $null
        if ($msg.ContainsKey('created_at') -and $msg['created_at']) { $tsRaw = [string]$msg['created_at'] }
        elseif ($convCreated) { $tsRaw = $convCreated }
        else { continue }

        try { $iso = [DateTimeOffset]::Parse($tsRaw).ToLocalTime().ToString('o') } catch { continue }

        [void]$entries.Add([PSCustomObject]@{ Ts = $iso; Session = $sessionHash; Body = $body })
    }
}
$sha.Dispose()

if ($entries.Count -eq 0) {
    Write-Host "Found $convCount conversations but no human prompts to import." -ForegroundColor Yellow
    exit 1
}

$rawFile = Join-Path $CorpusRoot '_raw-claude-ai.md'
if (-not (Test-Path $CorpusRoot)) { New-Item -ItemType Directory -Path $CorpusRoot -Force | Out-Null }

$header = @"
# Raw Prompt Log: Claude.ai / Claude Desktop (imported from official data export)

Your prompts (human messages only) from a claude.ai data export
(Settings -> Privacy -> Export data). Assistant replies are not imported.
Regenerated from scratch by ``tools/import-claude-export.ps1`` on each import;
re-import a newer export to replace this file.

Source export: $ExportPath
Imported: $((Get-Date).ToString('o'))
Conversations: $convCount | Prompts: $($entries.Count)

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

Write-Host "Imported $($entries.Count) prompts from $convCount Claude.ai conversations into $rawFile" -ForegroundColor Green
Write-Host "Run refresh.ps1 to fold them into entries.jsonl / sessions.jsonl." -ForegroundColor Cyan
Write-Host "The export zip contains your full history - store it somewhere private or delete it after import." -ForegroundColor Yellow

exit 0
