# curate.ps1
# Auto-curation engine for an AI prompt corpus.
#
# Reads _RAW_PROMPT_LOG.md (and any sibling _raw-*.md files), parses entries,
# classifies them by deterministic heuristics, groups them by session, and
# regenerates these views from scratch each run:
#
#   curated/<bucket>.md       - entries classified into thematic buckets
#   curated/_unclassified.md  - entries no heuristic caught (review to improve)
#   curated/_manifest.json    - last run + counts
#   sessions/<hash>.md        - one file per session
#   sessions/INDEX.md         - sortable table of every session
#   entries.jsonl             - machine-readable, one entry per line
#   sessions.jsonl            - machine-readable session manifest
#
# LLM-agnostic: pure regex/length heuristics, no API calls.
# Idempotent: same raw input always produces the same output.
# Multi-bucket: a single entry can land in multiple bucket views.

[CmdletBinding()]
param(
    [string]$CorpusRoot = $(
        if ($env:CORPUS_ROOT) { $env:CORPUS_ROOT }
        else {
            $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
            Join-Path $h 'corpus'
        }
    ),
    [switch]$Summary
)

$ErrorActionPreference = 'SilentlyContinue'

$curatedDir = Join-Path $CorpusRoot 'curated'
$sessionsDir = Join-Path $CorpusRoot 'sessions'
if (-not (Test-Path $CorpusRoot))  { New-Item -ItemType Directory -Path $CorpusRoot  -Force | Out-Null }
if (-not (Test-Path $curatedDir))  { New-Item -ItemType Directory -Path $curatedDir  -Force | Out-Null }
if (-not (Test-Path $sessionsDir)) { New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null }

# ----------------------------------------------------------------------
# 1. Collect raw sources
# ----------------------------------------------------------------------
$rawFiles = @()
$primary = Join-Path $CorpusRoot '_RAW_PROMPT_LOG.md'
if (Test-Path $primary) { $rawFiles += @{ Path = $primary; Source = 'claude' } }
Get-ChildItem -Path $CorpusRoot -Filter '_raw-*.md' -File -ErrorAction SilentlyContinue | ForEach-Object {
    $src = $_.BaseName -replace '^_raw-', ''
    $rawFiles += @{ Path = $_.FullName; Source = $src }
}

# ----------------------------------------------------------------------
# 2. Parse entries
# ----------------------------------------------------------------------
# Supports three formats (all backward-compatible):
#   v1: "## <ts>\n\n<body>\n\n---"
#   v2: "## <ts>\n> cwd: <path>\n\n<body>\n\n---"
#   v3: "## <ts>\n> cwd: <path>\n> session: <hash>\n\n<body>\n\n---"
$allEntries = @()
foreach ($rf in $rawFiles) {
    $content = Get-Content $rf.Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) { continue }

    # Terminator anchored to EXACTLY three dashes on their own line: entry
    # bodies are untrusted text (imported chat history), and the importers
    # widen embedded "---" lines to "----" so they cannot terminate an entry
    # early and forge subsequent entries.
    $matches = [regex]::Matches($content,
        '(?ms)^## (\S+)(?:\r?\n> cwd: ([^\r\n]+))?(?:\r?\n> session: ([^\r\n]+))?\r?\n\r?\n(.+?)(?=\r?\n\r?\n---[ \t]*\r?$|\z)')
    foreach ($m in $matches) {
        $ts      = $m.Groups[1].Value
        $cwd     = if ($m.Groups[2].Success) { $m.Groups[2].Value.Trim() } else { $null }
        $session = if ($m.Groups[3].Success) { $m.Groups[3].Value.Trim() } else { 'pre-session' }
        # Session becomes a filename under sessions/; never let a parsed value
        # traverse paths.
        if ($session -notmatch '^[a-z0-9][a-z0-9\-]{0,63}$') { $session = 'pre-session' }
        $body    = $m.Groups[4].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($body)) { continue }

        $source = if ($cwd) { Split-Path -Leaf $cwd } else { $rf.Source }

        $allEntries += [PSCustomObject]@{
            Timestamp = $ts
            Body      = $body
            Length    = $body.Length
            Source    = $source
            Cwd       = $cwd
            Session   = $session
        }
    }
}

# ----------------------------------------------------------------------
# 3. Classification heuristics
# ----------------------------------------------------------------------
# These are intentionally generic. Improve them by editing this function.
# Each entry can land in multiple buckets (multi-tag).
#
# To add a bucket for YOUR product names (e.g. "MyProduct development"),
# uncomment the example block at the bottom and edit the regex. Then add
# the bucket name to the $buckets ordered hashtable below.
function Get-Tags {
    param($Entry)
    $tags = New-Object System.Collections.Generic.HashSet[string]
    $b = $Entry.Body
    $len = $Entry.Length

    # Dictation: long, conversational
    if ($len -gt 300 -and $b -match '(?i)\b(actually|wait|sort of|you know|I mean|kind of|basically|like a)\b') {
        [void]$tags.Add('dictations')
    }
    if ($len -gt 500) { [void]$tags.Add('dictations') }

    # Strategy: thinking-out-loud, decisions, "I want / need / think", questions
    if ($b -match '(?i)\b(I think|I want to|I need to|I''d like|the reason|we should|should I|how do we|why (do|is|are)|what (is|are|if))\b') {
        [void]$tags.Add('strategy')
    }
    if ($b -match '(?i)\b(strategy|direction|plan|approach|framework|philosophy|positioning|brand)\b') {
        [void]$tags.Add('strategy')
    }

    # Agent briefs: language used to brief agents / define roles
    if ($b -match '(?i)\b(agent|MCP|hook|claude code|codex|tool use|sub.?agent|contract|role|brief|instruction)\b') {
        [void]$tags.Add('agent-briefs')
    }

    # Content ideas: anything that mentions a post, video, or piece of content
    if ($b -match '(?i)\b(post|posting|linkedin|youtube|video|short|tutorial|deep dive|content|caption|thumbnail|script|essay|blog|substack)\b') {
        [void]$tags.Add('content-ideas')
    }

    # EXAMPLE: bucket for your own product/project names. Uncomment and edit.
    # if ($b -match '(?i)\b(YourProduct|YourOtherProject|YourThing)\b') {
    #     [void]$tags.Add('product-threads')
    # }

    return $tags
}

# ----------------------------------------------------------------------
# 4. Heuristic purpose label for a session
# ----------------------------------------------------------------------
# Maps the session's primary source (derived from cwd leaf) to a human label.
# Add cases for your own project directories here.
function Get-SessionPurpose {
    param($Source, $TopBuckets)
    switch -Regex ($Source) {
        '^codex$'     { return 'Codex CLI session' }
        '^claude$'    { return 'Claude session (pre-cwd capture)' }
        '^chatgpt$'     { return 'ChatGPT conversation (imported export)' }
        '^claude-code$' { return 'Claude Code session (imported history, pre-cwd)' }
        '^claude-ai$' { return 'Claude.ai conversation (imported export)' }
        '^gemini$'    { return 'Gemini activity (one session per day)' }
        default {
            if ($Source -and $Source -ne 'pre-session') { return "Project: $Source" }
            return 'Ad-hoc / unknown'
        }
    }
}

# ----------------------------------------------------------------------
# 5. Group by bucket
# ----------------------------------------------------------------------
# To add a bucket, add a key here AND add the corresponding tag in Get-Tags.
$buckets = [ordered]@{
    'dictations'    = New-Object System.Collections.ArrayList
    'strategy'      = New-Object System.Collections.ArrayList
    'agent-briefs'  = New-Object System.Collections.ArrayList
    'content-ideas' = New-Object System.Collections.ArrayList
    # 'product-threads' = New-Object System.Collections.ArrayList  # uncomment if using
}
$unclassified = New-Object System.Collections.ArrayList

$entryTags = @{}
foreach ($e in $allEntries) {
    $tags = Get-Tags -Entry $e
    $entryTags["$($e.Session)|$($e.Timestamp)"] = $tags
    if ($tags.Count -eq 0) {
        [void]$unclassified.Add($e)
        continue
    }
    foreach ($tag in $tags) {
        if ($buckets.Contains($tag)) {
            [void]$buckets[$tag].Add($e)
        }
    }
}

# ----------------------------------------------------------------------
# 6. Group by session and derive session metadata
# ----------------------------------------------------------------------
$sessionGroups = $allEntries | Group-Object -Property Session
$sessionMeta = @{}
foreach ($g in $sessionGroups) {
    $hash = $g.Name
    $entries = @($g.Group | Sort-Object Timestamp)
    $firstEntry = $entries[0]
    $lastEntry  = $entries[-1]

    $bucketCounts = @{}
    foreach ($e in $entries) {
        foreach ($t in $entryTags["$($e.Session)|$($e.Timestamp)"]) {
            if (-not $bucketCounts.ContainsKey($t)) { $bucketCounts[$t] = 0 }
            $bucketCounts[$t]++
        }
    }
    $topBuckets = $bucketCounts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 3

    $primarySource = ($entries | Group-Object -Property Source | Sort-Object -Property Count -Descending | Select-Object -First 1).Name

    $purpose = Get-SessionPurpose -Source $primarySource -TopBuckets $topBuckets

    $sessionMeta[$hash] = [PSCustomObject]@{
        Hash         = $hash
        Source       = $primarySource
        Cwd          = $firstEntry.Cwd
        Purpose      = $purpose
        FirstSeen    = $firstEntry.Timestamp
        LastSeen     = $lastEntry.Timestamp
        EntryCount   = $entries.Count
        BucketCounts = $bucketCounts
        Entries      = $entries
    }
}

# ----------------------------------------------------------------------
# 7. Write each bucket file (regenerate from scratch, enriched with agent header)
# ----------------------------------------------------------------------
$bucketDescriptions = @{
    'dictations'      = 'Long, conversational entries - natural-voice samples for voice fingerprinting.'
    'strategy'        = 'Thinking-out-loud, decisions, and direction-setting.'
    'agent-briefs'    = 'Language used to brief agents and define roles.'
    'content-ideas'   = 'Anything that mentions a post, video, or piece of content.'
    'product-threads' = 'Custom: mentions of your specific product/project names.'
}

foreach ($bucket in $buckets.Keys) {
    $entries = $buckets[$bucket]
    $desc = $bucketDescriptions[$bucket]

    $header = @"
# curated/$bucket.md

> $desc
>
> Auto-generated by ``tools/curate.ps1`` from ``_RAW_PROMPT_LOG.md`` (and ``_raw-*.md`` siblings).
> Last regenerated: $((Get-Date).ToString('o')).
> Edit the source, not this file. Re-run curation to refresh.

Entry count: $($entries.Count)

---

"@

    $body = ''
    foreach ($e in $entries) {
        $meta = $sessionMeta[$e.Session]
        $purpose = if ($meta) { $meta.Purpose } else { 'unknown' }
        $body += "## $($e.Timestamp)`n> Agent#$($e.Session) | Purpose: $purpose | Source: $($e.Source)`n`n$($e.Body)`n`n---`n`n"
    }

    [System.IO.File]::WriteAllText((Join-Path $curatedDir "$bucket.md"), ($header + $body), [System.Text.UTF8Encoding]::new($false))
}

# Unclassified
if ($unclassified.Count -gt 0) {
    $header = @"
# curated/_unclassified.md

> Entries that didn't match any bucket heuristic. Review these to improve ``tools/curate.ps1``.
> Last regenerated: $((Get-Date).ToString('o')).

Entry count: $($unclassified.Count)

---

"@
    $body = ''
    foreach ($e in $unclassified) {
        $meta = $sessionMeta[$e.Session]
        $purpose = if ($meta) { $meta.Purpose } else { 'unknown' }
        $body += "## $($e.Timestamp)`n> Agent#$($e.Session) | Purpose: $purpose | Source: $($e.Source) | len: $($e.Length)`n`n$($e.Body)`n`n---`n`n"
    }
    [System.IO.File]::WriteAllText((Join-Path $curatedDir "_unclassified.md"), ($header + $body), [System.Text.UTF8Encoding]::new($false))
}

# ----------------------------------------------------------------------
# 8. Per-session summary files + INDEX
# ----------------------------------------------------------------------
Get-ChildItem -Path $sessionsDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

foreach ($hash in $sessionMeta.Keys) {
    $m = $sessionMeta[$hash]
    $bucketLine = ($m.BucketCounts.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object { "$($_.Key) ($($_.Value))" }) -join ', '
    if ([string]::IsNullOrWhiteSpace($bucketLine)) { $bucketLine = '(all unclassified)' }

    $sessionBody = @"
# Session Agent#$hash

**Purpose (heuristic):** $($m.Purpose)
**Source:** $($m.Source)
**Working directory:** $($m.Cwd)
**First seen:** $($m.FirstSeen)
**Last seen:** $($m.LastSeen)
**Entries:** $($m.EntryCount)
**Bucket distribution:** $bucketLine

---

## Entries (chronological)

"@
    foreach ($e in $m.Entries) {
        $preview = if ($e.Body.Length -gt 140) { $e.Body.Substring(0, 140) + '...' } else { $e.Body }
        $preview = $preview -replace '\r?\n', ' '
        $tagList = ($entryTags["$($e.Session)|$($e.Timestamp)"] | Sort-Object) -join ', '
        if ([string]::IsNullOrWhiteSpace($tagList)) { $tagList = 'unclassified' }
        $sessionBody += "- **$($e.Timestamp)** [$tagList] $preview`n"
    }

    [System.IO.File]::WriteAllText((Join-Path $sessionsDir "$hash.md"), $sessionBody, [System.Text.UTF8Encoding]::new($false))
}

$indexHeader = @"
# Sessions INDEX

Auto-generated by ``tools/curate.ps1``. One row per session, sorted most recent first.
Open ``sessions/<hash>.md`` for the full per-session view.

Last regenerated: $((Get-Date).ToString('o'))

| Agent | Purpose | Source | Started | Last seen | Entries |
|-------|---------|--------|---------|-----------|---------|
"@
$indexRows = ''
$sortedSessions = $sessionMeta.Values | Sort-Object -Property LastSeen -Descending
foreach ($m in $sortedSessions) {
    $indexRows += "| [#$($m.Hash)]($($m.Hash).md) | $($m.Purpose) | $($m.Source) | $($m.FirstSeen) | $($m.LastSeen) | $($m.EntryCount) |`n"
}
[System.IO.File]::WriteAllText((Join-Path $sessionsDir 'INDEX.md'), ($indexHeader + "`n" + $indexRows), [System.Text.UTF8Encoding]::new($false))

# ----------------------------------------------------------------------
# 9. JSONL exports (machine-readable parallel views)
# ----------------------------------------------------------------------
$entriesJsonl = Join-Path $CorpusRoot 'entries.jsonl'
$sessionsJsonl = Join-Path $CorpusRoot 'sessions.jsonl'

$entriesWriter = [System.IO.StreamWriter]::new($entriesJsonl, $false, [System.Text.UTF8Encoding]::new($false))
try {
    foreach ($e in ($allEntries | Sort-Object Timestamp)) {
        $tagArr = [string[]](@($entryTags["$($e.Session)|$($e.Timestamp)"]) | Sort-Object)
        if ($null -eq $tagArr) { $tagArr = [string[]]@() }
        $rec = [ordered]@{
            ts   = $e.Timestamp
            sess = $e.Session
            src  = $e.Source
            cwd  = $e.Cwd
            tags = $tagArr
            len  = $e.Length
            body = $e.Body
        }
        $entriesWriter.WriteLine(([PSCustomObject]$rec | ConvertTo-Json -Compress -Depth 4))
    }
} finally {
    $entriesWriter.Dispose()
}

$sessionsWriter = [System.IO.StreamWriter]::new($sessionsJsonl, $false, [System.Text.UTF8Encoding]::new($false))
try {
    foreach ($m in ($sessionMeta.Values | Sort-Object -Property LastSeen -Descending)) {
        $bucketObj = [ordered]@{}
        foreach ($k in ($m.BucketCounts.Keys | Sort-Object)) {
            $bucketObj[$k] = $m.BucketCounts[$k]
        }
        $rec = [ordered]@{
            hash    = $m.Hash
            purpose = $m.Purpose
            src     = $m.Source
            cwd     = $m.Cwd
            first   = $m.FirstSeen
            last    = $m.LastSeen
            count   = $m.EntryCount
            buckets = $bucketObj
        }
        $sessionsWriter.WriteLine(($rec | ConvertTo-Json -Compress -Depth 4))
    }
} finally {
    $sessionsWriter.Dispose()
}

# ----------------------------------------------------------------------
# 10. Manifest
# ----------------------------------------------------------------------
$manifest = [ordered]@{
    LastRun         = (Get-Date).ToString('o')
    TotalRawSources = $rawFiles.Count
    TotalEntries    = $allEntries.Count
    TotalSessions   = $sessionMeta.Count
    Buckets         = [ordered]@{}
}
foreach ($b in $buckets.Keys) {
    $manifest.Buckets[$b] = $buckets[$b].Count
}
$manifest.Unclassified = $unclassified.Count
$manifest.MachineExports = [ordered]@{
    'entries.jsonl'  = (Get-Item $entriesJsonl).Length
    'sessions.jsonl' = (Get-Item $sessionsJsonl).Length
}
[System.IO.File]::WriteAllText((Join-Path $curatedDir '_manifest.json'), ($manifest | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))

if ($Summary) {
    Write-Host "Curation complete."
    Write-Host "Total entries:  $($allEntries.Count)"
    Write-Host "Total sessions: $($sessionMeta.Count)"
    foreach ($b in $buckets.Keys) {
        Write-Host "  $b : $($buckets[$b].Count)"
    }
    Write-Host "  _unclassified: $($unclassified.Count)"
    Write-Host ""
    Write-Host "Sessions:"
    foreach ($m in $sortedSessions) {
        Write-Host "  Agent#$($m.Hash)  $($m.Purpose) ($($m.Source), $($m.EntryCount) entries)"
    }
}

exit 0
