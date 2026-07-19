# import-export-common.ps1
# Shared helpers for the export importers (ChatGPT, Claude.ai, Gemini Takeout).
# Dot-sourced; not meant to be run directly.

# Locate a JSON file inside an export, given as a zip, a bare .json file, or a
# directory. Zips are read IN-MEMORY via System.IO.Compression - nothing from
# an untrusted archive is ever extracted to disk (no zip-slip surface).
# $EntryPathPattern optionally narrows zip/directory matches by full path
# (e.g. 'Gemini' to pick the Gemini MyActivity.json out of a Takeout archive).
function Get-ExportJsonText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$CandidateNames,
        [string]$EntryPathPattern = ''
    )

    if (-not (Test-Path $Path)) { return $null }
    $item = Get-Item $Path

    if (-not $item.PSIsContainer -and $item.Extension -eq '.zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($item.FullName)
        try {
            $entry = $zip.Entries | Where-Object {
                $CandidateNames -contains $_.Name -and
                (-not $EntryPathPattern -or $_.FullName -match $EntryPathPattern)
            } | Select-Object -First 1
            if (-not $entry) { return $null }
            # Cap decompressed size: a small crafted zip can declare gigabytes.
            if ($entry.Length -gt 1GB) {
                Write-Host "Refusing to read $($entry.Name): declares $([math]::Round($entry.Length / 1MB)) MB uncompressed." -ForegroundColor Red
                return $null
            }
            # Bounded read loop rather than ReadToEnd: the declared length can
            # lie, so enforce the cap on actual decompressed output too.
            $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
            try {
                $sb = New-Object System.Text.StringBuilder
                $chunk = New-Object char[] 131072
                $total = [int64]0
                while (($n = $reader.Read($chunk, 0, $chunk.Length)) -gt 0) {
                    $total += $n
                    if ($total -gt 1GB) {
                        Write-Host "Refusing to read $($entry.Name): decompressed output exceeded 1 GB." -ForegroundColor Red
                        return $null
                    }
                    [void]$sb.Append($chunk, 0, $n)
                }
                return $sb.ToString()
            } finally { $reader.Dispose() }
        } finally {
            $zip.Dispose()
        }
    }

    if ($item.PSIsContainer) {
        $found = Get-ChildItem -Path $item.FullName -Recurse -Depth 4 -File -ErrorAction SilentlyContinue |
            Where-Object {
                $CandidateNames -contains $_.Name -and
                (-not $EntryPathPattern -or $_.FullName -match $EntryPathPattern)
            } | Select-Object -First 1
        if (-not $found) { return $null }
        return [System.IO.File]::ReadAllText($found.FullName, [System.Text.UTF8Encoding]::new($false))
    }

    # A file passed directly - trust the user's pointer regardless of name
    return [System.IO.File]::ReadAllText($item.FullName, [System.Text.UTF8Encoding]::new($false))
}

# Parse JSON into IDictionary/array structures on both Windows PowerShell 5.1
# and PowerShell 7+. ConvertFrom-Json in 5.1 returns PSCustomObjects (awkward
# for dictionary-shaped data like ChatGPT's "mapping") and struggles with
# large files, so 5.1 uses JavaScriptSerializer instead. Both paths return
# objects where maps support .Contains()/['key'] and lists enumerate.
function ConvertFrom-JsonPortable {
    param([Parameter(Mandatory = $true)][string]$Text)

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return ,($Text | ConvertFrom-Json -AsHashtable -Depth 100)
    }

    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.RecursionLimit = 1000
    return ,$serializer.DeserializeObject($Text)
}

# A line consisting only of three dashes inside a body would terminate the
# entry early when curate.ps1 parses the raw markdown. Widen to four dashes
# (still a markdown horizontal rule, so rendering is unchanged).
function Protect-EntryBody {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return ($Text -replace '(?m)^[ \t]*-{3}[ \t]*$', '----').Trim()
}
