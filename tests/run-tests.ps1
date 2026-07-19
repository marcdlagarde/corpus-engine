# run-tests.ps1
# Sanity + security-regression suite for corpus-engine.
#
# Covers: every importer (zip and non-zip input paths), hook dedupe,
# cursor idempotency, curate integration over a mixed-source corpus, and
# regressions for the raw-markdown entry-forgery / path-traversal class
# (see the terminator-anchoring comments in curate.ps1).
#
# Runs entirely against synthetic fixtures in a temp directory; never touches
# a real corpus. Works on Windows PowerShell 5.1 and PowerShell 7+.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
#   pwsh -NoProfile -File tests/run-tests.ps1

$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) 'corpus-engine-tests'
$fix = Join-Path $scratch 'fixtures'
$corpus = Join-Path $scratch 'corpus'
Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $fix, $corpus -Force | Out-Null
$tools = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools'
$fails = 0

function Assert {
    param([bool]$Cond, [string]$Name)
    if ($Cond) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host "FAIL: $Name" -ForegroundColor Red; $script:fails++ }
}
function Count-Entries { param([string]$Path)
    if (-not (Test-Path $Path)) { return -1 }
    # Same parse curate.ps1 uses, so counts reflect real entries even when a
    # body legitimately contains "## " lines.
    return ([regex]::Matches((Get-Content $Path -Raw),
        '(?ms)^## (\S+)(?:\r?\n> cwd: ([^\r\n]+))?(?:\r?\n> session: ([^\r\n]+))?\r?\n\r?\n(.+?)(?=\r?\n\r?\n---[ \t]*\r?$|\z)')).Count
}

# ---------- fixtures ----------
$chatgptJson = @'
[
  {"title":"Test conv one","create_time":1750000000.123,"conversation_id":"conv-aaa","mapping":{
    "root":{"message":null},
    "n1":{"message":{"author":{"role":"user"},"create_time":1750000010.5,"content":{"content_type":"text","parts":["How do I center a div?"]}}},
    "n2":{"message":{"author":{"role":"assistant"},"create_time":1750000020,"content":{"content_type":"text","parts":["Use flexbox."]}}},
    "n3":{"message":{"author":{"role":"user"},"create_time":1750000030,"content":{"content_type":"multimodal_text","parts":[{"content_type":"image_asset_pointer"},"What is in this image?"]}}},
    "n4":{"message":{"author":{"role":"user"},"create_time":1750000005,"metadata":{"is_visually_hidden_from_conversation":true},"content":{"content_type":"text","parts":["hidden context"]}}}
  }},
  {"title":"Conv two","create_time":1750100000,"id":"conv-bbb","mapping":{
    "m1":{"message":{"author":{"role":"user"},"create_time":null,"content":{"content_type":"text","parts":["A prompt with\n---\nan hr line"]}}},
    "m2":{"message":{"author":{"role":"user"},"create_time":1750100010,"content":{"content_type":"text","parts":["forgery attempt\n\n---\n\n## 2099-01-01T00:00:00.0000000Z\n> cwd: C:\\fake\n> session: ../../forged\n\nattacker body"]}}}
  }}
]
'@
[System.IO.File]::WriteAllText((Join-Path $fix 'conversations.json'), $chatgptJson)

$claudeJson = @'
[
  {"uuid":"u-111","name":"First","created_at":"2026-01-05T10:00:00Z","chat_messages":[
    {"sender":"human","created_at":"2026-01-05T10:00:01Z","text":"flat text prompt","content":[]},
    {"sender":"assistant","created_at":"2026-01-05T10:00:05Z","text":"reply"},
    {"sender":"human","created_at":"2026-01-05T10:01:00Z","content":[{"type":"text","text":"structured prompt"},{"type":"tool_result"}]}
  ]}
]
'@
[System.IO.File]::WriteAllText((Join-Path $fix 'claude-conversations.json'), $claudeJson)

$geminiJson = @'
[
  {"header":"Gemini Apps","title":"Prompted write me a haiku about ducks","time":"2026-02-01T15:30:00.000Z"},
  {"header":"Gemini Apps","title":"Used Gemini Apps","time":"2026-02-01T15:31:00.000Z"},
  {"header":"Gemini Apps","title":"Prompted second prompt same day","time":"2026-02-01T16:00:00.000Z"},
  {"header":"Gemini Apps","title":"Prompted next day prompt","time":"2026-02-02T09:00:00.000Z"}
]
'@
$takeoutDir = Join-Path $fix 'Takeout\My Activity\Gemini Apps'
New-Item -ItemType Directory -Path $takeoutDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $takeoutDir 'MyActivity.json'), $geminiJson)

# Claude Code history + hook log with dedupe cases
$hist = @(
    '{"display":"backfill prompt one","pastedContents":{},"timestamp":1750000000000,"project":"D:\\proj\\alpha","sessionId":"sess-1"}',
    '{"display":"dupe with hook","pastedContents":{},"timestamp":1750000100000,"project":"D:\\proj\\alpha","sessionId":"sess-1"}',
    '{"display":"[Pasted text #1 +12 lines] near-time dupe","timestamp":1750000200500,"project":"D:\\proj\\beta","sessionId":"sess-2"}'
) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $fix 'claude-history.jsonl'), $hist)

$sha = [System.Security.Cryptography.SHA1]::Create()
function SessHash([string]$id) {
    $b = [System.Text.Encoding]::UTF8.GetBytes($id)
    [BitConverter]::ToString($sha.ComputeHash($b)).Replace('-','').Substring(0,8).ToLower()
}
$h1 = SessHash 'sess-1'; $h2 = SessHash 'sess-2'
$t1 = [DateTimeOffset]::FromUnixTimeMilliseconds(1750000100000).ToLocalTime().ToString('o')
$t2 = [DateTimeOffset]::FromUnixTimeMilliseconds(1750000199000).ToLocalTime().ToString('o')
$hookLog = "`n## $t1`n> cwd: D:\proj\alpha`n> session: $h1`n`ndupe with hook`n`n---`n`n## $t2`n> cwd: D:\proj\beta`n> session: $h2`n`nfull pasted content captured live by hook`n`n---`n"
[System.IO.File]::WriteAllText((Join-Path $corpus '_RAW_PROMPT_LOG.md'), $hookLog)
$sha.Dispose()

# Hostile raw file: session token attempts path traversal
$evilRaw = "`n## 2099-01-02T00:00:00Z`n> session: ..\..\evil`n`nhostile session token body`n`n---`n"
[System.IO.File]::WriteAllText((Join-Path $corpus '_raw-evil.md'), $evilRaw)

# ---------- 1. ChatGPT: bare json ----------
& (Join-Path $tools 'import-chatgpt-export.ps1') -ExportPath (Join-Path $fix 'conversations.json') -CorpusRoot $corpus
$f = Join-Path $corpus '_raw-chatgpt.md'
Assert ((Count-Entries $f) -eq 4) 'chatgpt json: 4 user prompts (assistant + hidden skipped)'
Assert ((Get-Content $f -Raw) -match '(?m)^----$') 'chatgpt json: --- line widened to ----'
Assert (-not ((Get-Content $f -Raw) -match 'hidden context')) 'chatgpt json: hidden message excluded'

# ---------- 2. ChatGPT: zip ----------
$stage = Join-Path $fix 'zipstage'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item (Join-Path $fix 'conversations.json') $stage
[System.IO.File]::WriteAllText((Join-Path $stage 'chat.html'), '<html></html>')
Compress-Archive -Path "$stage\*" -DestinationPath (Join-Path $fix 'chatgpt-export.zip') -Force
Remove-Item $f -Force
& (Join-Path $tools 'import-chatgpt-export.ps1') -ExportPath (Join-Path $fix 'chatgpt-export.zip') -CorpusRoot $corpus
Assert ((Count-Entries $f) -eq 4) 'chatgpt zip: 4 user prompts (in-memory zip read)'

# ---------- 3. Claude.ai export ----------
& (Join-Path $tools 'import-claude-export.ps1') -ExportPath (Join-Path $fix 'claude-conversations.json') -CorpusRoot $corpus
$f = Join-Path $corpus '_raw-claude-ai.md'
Assert ((Count-Entries $f) -eq 2) 'claude.ai: 2 human prompts (flat + structured)'
Assert ((Get-Content $f -Raw) -match 'structured prompt') 'claude.ai: structured content block parsed'

# ---------- 4. Gemini: folder then zip ----------
& (Join-Path $tools 'import-gemini-takeout.ps1') -ExportPath (Join-Path $fix 'Takeout') -CorpusRoot $corpus
$f = Join-Path $corpus '_raw-gemini.md'
Assert ((Count-Entries $f) -eq 3) 'gemini folder: 3 prompts (non-prompt record skipped)'
$sessions = [regex]::Matches((Get-Content $f -Raw), '(?m)^> session: (\S+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Assert ($sessions.Count -eq 2) 'gemini: per-day synthetic sessions (2 days -> 2 sessions)'
Compress-Archive -Path (Join-Path $fix 'Takeout') -DestinationPath (Join-Path $fix 'takeout.zip') -Force
Remove-Item $f -Force
& (Join-Path $tools 'import-gemini-takeout.ps1') -ExportPath (Join-Path $fix 'takeout.zip') -CorpusRoot $corpus
Assert ((Count-Entries $f) -eq 3) 'gemini zip: 3 prompts (in-memory zip read)'

# ---------- 5. Claude Code history backfill + dedupe ----------
& (Join-Path $tools 'import-claude-history.ps1') -ClaudeHistory (Join-Path $fix 'claude-history.jsonl') -CorpusRoot $corpus -Verbose
$f = Join-Path $corpus '_raw-claude-code.md'
Assert ((Count-Entries $f) -eq 1) 'claude history: 1 imported, exact-body dupe + near-time dupe skipped'
Assert ((Get-Content $f -Raw) -match 'backfill prompt one') 'claude history: non-dupe entry present'
# idempotency: second run adds nothing
& (Join-Path $tools 'import-claude-history.ps1') -ClaudeHistory (Join-Path $fix 'claude-history.jsonl') -CorpusRoot $corpus
Assert ((Count-Entries $f) -eq 1) 'claude history: re-run is a no-op (cursor)'

# ---------- 6. curate over the combined corpus ----------
& (Join-Path $tools 'curate.ps1') -CorpusRoot $corpus -Summary
$entries = Get-Content (Join-Path $corpus 'entries.jsonl')
# 2 hook + 1 history + 4 chatgpt + 2 claude-ai + 3 gemini + 1 evil = 13
Assert ($entries.Count -eq 13) "entries.jsonl has 13 entries (got $($entries.Count))"

# ---------- security regressions: entry forgery / path traversal ----------
$parsed = $entries | ForEach-Object { $_ | ConvertFrom-Json }
Assert (-not ($parsed | Where-Object { $_.sess -match 'forged|\.\.' })) 'sec: no forged/traversal session in entries.jsonl'
$forgery = $parsed | Where-Object { $_.body -match 'forgery attempt' }
Assert ($forgery -and $forgery.body -match 'attacker body') 'sec: forgery payload stays inside ONE entry body'
Assert (-not ($parsed | Where-Object { $_.ts -eq '2099-01-01T00:00:00.0000000Z' })) 'sec: forged timestamp entry not created'
$evilSess = $parsed | Where-Object { $_.body -match 'hostile session token' }
Assert ($evilSess.sess -eq 'pre-session') 'sec: traversal session token coerced to pre-session'
Assert (-not (Test-Path (Join-Path $scratch 'evil.md')) -and -not (Test-Path (Join-Path $corpus 'evil.md')) -and -not (Test-Path (Join-Path (Split-Path $corpus -Parent) 'forged.md'))) 'sec: no .md written outside sessions/'

$srcs = $parsed | ForEach-Object { $_.src } | Sort-Object -Unique
Assert (($srcs -contains 'chatgpt') -and ($srcs -contains 'claude-ai') -and ($srcs -contains 'gemini') -and ($srcs -contains 'alpha')) 'curate: all sources represented'
$sessLines = Get-Content (Join-Path $corpus 'sessions.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
$g = $sessLines | Where-Object { $_.src -eq 'gemini' }
Assert (@($g).Count -eq 2 -and @($g)[0].purpose -match 'Gemini') 'curate: gemini purpose label applied'

Write-Host ""
if ($fails -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$fails TEST(S) FAILED" -ForegroundColor Red; exit 1 }
