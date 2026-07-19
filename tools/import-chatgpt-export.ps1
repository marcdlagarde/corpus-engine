# import-chatgpt-export.ps1
# Imports YOUR prompts from a ChatGPT data export into the corpus lake.
#
# ChatGPT (Desktop, web, and mobile all share one server-side history) has no
# readable local history file. The supported path is the official export:
#   ChatGPT -> Settings -> Data Controls -> Export data
# OpenAI emails a zip containing conversations.json (complete history).
#
# Usage:
#   .\import-chatgpt-export.ps1 -ExportPath ~\Downloads\chatgpt-export.zip
#   .\import-chatgpt-export.ps1 -ExportPath ~\Downloads\conversations.json
#
# -ExportPath accepts the zip itself, an extracted conversations.json, or a
# directory containing one. The zip is read in-memory (never extracted to
# disk). Only messages with author role "user" are imported - your prompts,
# not the assistant's replies.
#
# Regenerates <CorpusRoot>/_raw-chatgpt.md from scratch each run. Exports are
# always full-history snapshots, so re-importing a newer export simply
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
    Write-Host "Point -ExportPath at the export zip from ChatGPT Settings -> Data Controls -> Export data," -ForegroundColor Yellow
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
    foreach ($k in @('conversation_id', 'id', 'title')) {
        if ($conv.ContainsKey($k) -and $conv[$k]) { $convId = [string]$conv[$k]; break }
    }
    if (-not $convId) { $convId = "chatgpt-$convCount" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($convId)
    $sessionHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').Substring(0,8).ToLower()

    $convCreate = $null
    if ($conv.ContainsKey('create_time') -and $conv['create_time']) { $convCreate = [double]$conv['create_time'] }

    if (-not $conv.ContainsKey('mapping') -or -not ($conv['mapping'] -is [System.Collections.IDictionary])) { continue }

    foreach ($node in $conv['mapping'].Values) {
        if (-not ($node -is [System.Collections.IDictionary])) { continue }
        if (-not $node.ContainsKey('message') -or -not ($node['message'] -is [System.Collections.IDictionary])) { continue }
        $msg = $node['message']

        # Only the user's own prompts
        if (-not $msg.ContainsKey('author') -or -not ($msg['author'] -is [System.Collections.IDictionary])) { continue }
        if ([string]$msg['author']['role'] -ne 'user') { continue }

        # Skip system-injected user-role context (custom instructions, etc.)
        if ($msg.ContainsKey('metadata') -and ($msg['metadata'] -is [System.Collections.IDictionary]) -and
            $msg['metadata'].ContainsKey('is_visually_hidden_from_conversation') -and
            $msg['metadata']['is_visually_hidden_from_conversation']) { continue }

        if (-not $msg.ContainsKey('content') -or -not ($msg['content'] -is [System.Collections.IDictionary])) { continue }
        $content = $msg['content']
        if (-not $content.ContainsKey('parts')) { continue }

        $textParts = New-Object System.Collections.ArrayList
        foreach ($part in @($content['parts'])) {
            if ($part -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($part)) { [void]$textParts.Add($part) }
            } elseif (($part -is [System.Collections.IDictionary]) -and $part.ContainsKey('text') -and $part['text']) {
                [void]$textParts.Add([string]$part['text'])
            }
            # image/audio parts are skipped - prompts only
        }
        if ($textParts.Count -eq 0) { continue }
        $body = Protect-EntryBody -Text ($textParts -join "`n")
        if ([string]::IsNullOrWhiteSpace($body)) { continue }

        $msgTime = $null
        if ($msg.ContainsKey('create_time') -and $msg['create_time']) { $msgTime = [double]$msg['create_time'] }
        elseif ($null -ne $convCreate) { $msgTime = $convCreate }
        else { continue }

        $iso = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]($msgTime * 1000)).ToLocalTime().ToString('o')

        [void]$entries.Add([PSCustomObject]@{ Ts = $iso; Session = $sessionHash; Body = $body })
    }
}
$sha.Dispose()

if ($entries.Count -eq 0) {
    Write-Host "Found $convCount conversations but no user prompts to import." -ForegroundColor Yellow
    exit 1
}

$rawFile = Join-Path $CorpusRoot '_raw-chatgpt.md'
if (-not (Test-Path $CorpusRoot)) { New-Item -ItemType Directory -Path $CorpusRoot -Force | Out-Null }

$header = @"
# Raw Prompt Log: ChatGPT (imported from official data export)

Your prompts (user messages only) from a ChatGPT data export
(Settings -> Data Controls -> Export data). Assistant replies are not imported.
Regenerated from scratch by ``tools/import-chatgpt-export.ps1`` on each import;
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

Write-Host "Imported $($entries.Count) prompts from $convCount ChatGPT conversations into $rawFile" -ForegroundColor Green
Write-Host "Run refresh.ps1 to fold them into entries.jsonl / sessions.jsonl." -ForegroundColor Cyan
Write-Host "The export zip contains your full history - store it somewhere private or delete it after import." -ForegroundColor Yellow

exit 0
