# corpus-engine

> **Every Codex CLI user has thousands of their own prompts sitting on disk right now. Most don't know.**
> This is the engine I built to capture them, classify them, and ask questions of them in plain English. It also captures every prompt I send to Claude Code, across every project, automatically. Yours can too.

```
You -> Claude Code or Codex CLI -> this engine -> a queryable record of how you think
```

**v0.1, Windows-only, by [@marcdlagarde](https://github.com/marcdlagarde).** Rough edges, no UI, opinions baked in. Mac/Linux port: help wanted (see [Contributing](#contributing)).

---

## What it does

1. **Captures** every prompt you submit to Claude Code (via a `UserPromptSubmit` hook), every prompt you've ever sent to Codex CLI (via its built-in `~/.codex/history.jsonl`), and your entire Claude Code back-history (via `~/.claude/history.jsonl` — no waiting for the hook to accumulate).
1. **Imports** your history from ChatGPT (Desktop/web/mobile), Claude Desktop / claude.ai, and Gemini via each product's official data export — so people who have never touched a CLI still get a full corpus on day one.
2. **Classifies** them into themed buckets with deterministic heuristics (no LLM calls during classification): `dictations`, `strategy`, `agent-briefs`, `content-ideas`. Buckets are easy to add or rewrite.
3. **Groups** entries by session and gives each session a heuristic purpose label + bucket distribution + entry list.
4. **Exports** machine-readable JSONL parallel files (`entries.jsonl`, `sessions.jsonl`) so agents can query the corpus efficiently.
5. **Refreshes before query** with `refresh.ps1`, so `entries.jsonl` and `sessions.jsonl` include new Codex history and newly captured Claude prompts.
6. **Lets you ask** the corpus questions in plain English via `corpus-ask.ps1` (wraps `claude -p` with a tight system prompt; cites real timestamps).
7. **Backs up** to your own private GitHub repo every 30 minutes (optional, opt-in).

---

## Why it might matter to you

Open this file right now:
```
%USERPROFILE%\.codex\history.jsonl
```

If you've used Codex CLI in the last few months, that file has thousands of your own prompts in it. The version of you in there has been taking notes — every brief you wrote, every half-formed idea you prompted at 3am, every question you asked a model and forgot about. The file isn't a secret. It's [documented in OpenAI's config reference](https://developers.openai.com/codex/config-reference). It's just unadvertised, so most people never look.

This engine treats that file (and the Claude Code equivalent) as **source material**, not chat scrollback.

---

## Quickstart (Windows, one line)

Open PowerShell (press Win, type `powershell`, Enter) and paste:

```powershell
irm https://github.com/marcdlagarde/corpus-engine/releases/latest/download/install.ps1 | iex
```

That clones (or downloads — git not required) the repo to `~\corpus-engine`, runs `setup.ps1`, then runs `tools\doctor.ps1`, which tells you exactly which prompt-history sources exist on your machine and how to get the ones that don't. It installs nothing else and only prints the opt-in steps (hook, backup) for you to review.

The line serves the installer from the **latest release** and installs the latest release's code — deliberately tagged, reviewed versions, never whatever `main` happened to be at 3am. Release tags are protected against rewriting. To pin an exact version, set `$env:CORPUS_ENGINE_REF = 'v0.2.2'` first; to live on the bleeding edge instead, set it to `'main'`.

Prefer to do it by hand? Same thing:

```powershell
git clone https://github.com/marcdlagarde/corpus-engine.git
cd corpus-engine
.\setup.ps1
```

The setup script:
- Checks what's available (PowerShell, `claude` CLI — optional, Codex/Claude Code history)
- Creates your corpus directory (default: `~\corpus`, override with `$env:CORPUS_ROOT`)
- Installs `AGENTS.md` into your corpus directory so future Claude/Codex agents know how to refresh and query it
- Runs a curation pass against the bundled `samples/` so you immediately see real output
- Prints the manual steps for the Claude Code hook, the export importers, and the optional auto-backup

After setup, run `tools\refresh.ps1` once: it backfills everything already on your disk (Codex history + your full Claude Code history). The next prompt you submit to Claude Code lands in your corpus via the hook.

**Mac (experimental):** the importers, curation, and corpus-ask run under [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos) (`brew install powershell/tap/powershell`), then:

```sh
curl -fsSL https://github.com/marcdlagarde/corpus-engine/releases/latest/download/install.sh | sh
```

The live capture hook and scheduled backup are still Windows-only; on Mac your Claude Code history is backfilled from `~/.claude/history.jsonl` on every refresh instead.

---

## New to all of this? (ChatGPT / Claude Desktop / Gemini users)

You don't need to be a CLI user to build a corpus. A "CLI" (command-line interface) is just a program you type at instead of click at; the two relevant ones here are **Claude Code** (Anthropic) and **Codex** (OpenAI), and both are optional for getting started.

Your chat apps don't keep a readable history file on your computer — history lives on the vendor's servers. But every vendor lets you export it, and this engine imports all three:

| You use | Get your history | Then import with |
|---------|------------------|------------------|
| ChatGPT (Desktop, web, or mobile) | Settings → Data Controls → **Export data** (zip arrives by email) | `tools\import-chatgpt-export.ps1 -ExportPath <the zip>` |
| Claude Desktop / claude.ai | Settings → Privacy → **Export data** (link arrives by email, all tiers) | `tools\import-claude-export.ps1 -ExportPath <the zip>` |
| Gemini | [takeout.google.com](https://takeout.google.com) → My Activity → **Gemini Apps** only → format **JSON** | `tools\import-gemini-takeout.ps1 -ExportPath <the zip>` |

Then run `tools\refresh.ps1` and your corpus is live — browse it in any markdown reader, no AI subscription required.

Gemini fine print: the standalone "Gemini" Takeout product exports Gems, *not* chats — it must be My Activity → Gemini Apps. Work/Workspace accounts may have Takeout disabled by the admin, and if "Gemini Apps Activity" was off, there's no history to export.

Want the CLIs too? Official installers:

```powershell
# Claude Code (Windows)
irm https://claude.ai/install.ps1 | iex
# Codex CLI (needs Node.js from nodejs.org)
npm install -g @openai/codex
```

Not sure what you have? `tools\doctor.ps1` inventories your machine — CLIs, history files, hook status, even export zips sitting in your Downloads folder — and prints the exact command for each next step.

---

## Layout

```
corpus-engine/
├── install.ps1                  # one-line bootstrap (irm ... | iex)
├── install.sh                   # one-line bootstrap for Mac (experimental)
├── tools/
│   ├── log-prompt.ps1            # Claude Code UserPromptSubmit hook
│   ├── import-codex-history.ps1  # incremental Codex history.jsonl importer
│   ├── import-claude-history.ps1 # incremental ~/.claude/history.jsonl importer (deduped vs hook)
│   ├── import-chatgpt-export.ps1 # ChatGPT official data-export importer
│   ├── import-claude-export.ps1  # claude.ai official data-export importer
│   ├── import-gemini-takeout.ps1 # Google Takeout (Gemini Apps) importer
│   ├── import-export-common.ps1  # shared helpers for the export importers
│   ├── doctor.ps1                # read-only preflight: what sources does this machine have?
│   ├── refresh.ps1               # import Codex + Claude history, regenerate JSONL/markdown views
│   ├── curate.ps1                # classify + group + export (the main engine)
│   ├── corpus-ask.ps1            # natural-language query via claude -p
│   ├── backup.ps1                # commit + push (optional, opt-in)
│   └── setup-backup-task.ps1     # registers 30-min scheduled task (elevated)
├── samples/                     # synthetic demo corpus (run the engine against it first)
│   ├── _RAW_PROMPT_LOG.md        # hand-written sample prompts
│   ├── entries.jsonl             # machine-readable exports
│   ├── sessions.jsonl
│   ├── curated/                  # generated bucket views
│   └── sessions/                 # generated per-session views
├── templates/
│   └── AGENTS.md                 # installed into your corpus root by setup.ps1
├── tests/
│   └── run-tests.ps1             # importer + security-regression suite (PS 5.1 and PS 7)
├── AGENTS.md                     # instructions for agents working on this engine
├── setup.ps1                     # one-time install
├── LICENSE                       # MIT
└── README.md
```

Your corpus root (`~\corpus` by default) ends up structured like this:

```
~\corpus\
├── AGENTS.md             # tells future agents how to refresh/query this corpus
├── _RAW_PROMPT_LOG.md     # Claude Code live capture (firehose, append-only)
├── _raw-codex.md          # Codex CLI imports
├── _raw-claude-code.md    # Claude Code back-history import (if present)
├── _raw-chatgpt.md        # ChatGPT export import (if imported)
├── _raw-claude-ai.md      # claude.ai export import (if imported)
├── _raw-gemini.md         # Gemini Takeout import (if imported)
├── entries.jsonl          # machine-readable: one entry per line
├── sessions.jsonl         # machine-readable: one session per line
├── curated/               # human-readable views, regenerated each run
│   ├── dictations.md
│   ├── strategy.md
│   ├── agent-briefs.md
│   ├── content-ideas.md
│   ├── _unclassified.md
│   └── _manifest.json
└── sessions/
    ├── INDEX.md           # sortable table of every session
    └── <hash>.md          # per-session summary with chronological entries
```

---

## Viewing your corpus

Your corpus is plain markdown files on your disk. Any markdown reader works. Three options worth knowing:

**Plain text editor or VS Code preview.** Zero install. VS Code's built-in markdown preview (Ctrl+Shift+V) renders it cleanly with no extra tooling. Fine if you're already editing in VS Code.

**Obsidian** (personal recommendation). Free for personal use. Point it at your corpus folder as a vault and you get a file tree on the left, fast search, wiki-link rendering, and a reading mode (Ctrl+E) that hides the markdown syntax so it reads like a clean doc. Two-click setup. The wiki-link rendering matches the structure `curate.ps1` generates, so cross-references in your sessions and curated views become clickable navigation.

**Terminal + `corpus-ask`.** When you want the answer, not a browse. Fastest path once you already know what you're asking.

Pick what fits how you read. The corpus is the same files either way. The repo's `.gitignore` already blocks `.obsidian/`, so vault config never lands in your private corpus repo.

---

## Ask the corpus

`corpus-ask.ps1` refreshes `entries.jsonl` and `sessions.jsonl` before it asks, so new Codex history and new Claude hook captures are included. Use `-NoRefresh` only when you intentionally want to query the files exactly as they are.

```powershell
.\tools\corpus-ask.ps1 "what are my recurring themes across the last three months?"
.\tools\corpus-ask.ps1 -Model opus "compare how I articulated questions in January vs May"
.\tools\corpus-ask.ps1 -Trace "what files did you read to answer?"   # see tool calls
```

Add to your `$PROFILE` for one-word invocation:
```powershell
function corpus-ask { & 'C:\path\to\corpus-engine\tools\corpus-ask.ps1' @args }
```

Then:
```powershell
corpus-ask "find threads I started but abandoned"
```

The model navigates the JSONL exports with grep/Bash, cites specific entry timestamps, stops when done. Each query costs ~1 chunky Claude Code conversation worth of quota.

If Claude CLI auth fails, the local refresh still happened first. You can fix Claude auth and retry, or point another agent at the installed corpus and ask it to follow `AGENTS.md`.

---

## For agents (machine-readable)

If you're an LLM or another agent consuming this corpus programmatically, refresh first, then read the JSONL. Setup installs an `AGENTS.md` file into the user's corpus root with these instructions and the exact local tool paths.

```powershell
.\tools\refresh.ps1 -CorpusRoot "$env:USERPROFILE\corpus"
```

Then read these two files instead of parsing the markdown:

- **`entries.jsonl`** — one entry per line. Schema: `{ts, sess, src, cwd, tags, len, body}`. Filter by `sess` hash, `src` (cwd leaf), `tags` array, or `body` keywords. Stream-friendly.
- **`sessions.jsonl`** — one session per line. Schema: `{hash, purpose, src, cwd, first, last, count, buckets}`. Small (~tens of KB even at scale); safe to load fully as a manifest.

Markdown files in `curated/` and `sessions/` are derived views of the same data, regenerated by `curate.ps1` each run. The JSONL files are the canonical machine surface.

Direct-agent rule of thumb:

```text
Read AGENTS.md, run refresh.ps1, read sessions.jsonl, filter entries.jsonl, cite timestamps.
```

---

## Customize for your own projects

The classification heuristics in `tools/curate.ps1` are deterministic regex/length rules. To add a bucket for your own product names:

1. Open `tools/curate.ps1`
2. Find the `Get-Tags` function, uncomment the `product-threads` example, edit the regex with your own project names
3. Find the `$buckets = [ordered]@{ ... }` block, uncomment the `product-threads` line
4. Re-run `curate.ps1` — every old entry gets reclassified against the new rule automatically

Same pattern for adding entirely new buckets. Each iteration is one edit and one re-run.

---

## Privacy + safety

- **Your corpus is yours.** This engine writes to a local directory. It does not phone home, does not call any API except the one `corpus-ask` explicitly uses (Anthropic's, via your own `claude` CLI auth).
- **Never commit your real corpus publicly.** The `.gitignore` in this repo blocks the runtime files by default. If you wire up auto-backup, point it at a **private** GitHub repo.
- **The hook captures EVERYTHING you submit to Claude Code.** Including passwords pasted by accident, internal company names, anything. Treat the corpus as sensitive. If you're going to use this in a regulated environment, configure a project-specific hook scope instead of the user-global one.
- **Export zips are your full history.** The ChatGPT/Claude/Takeout zips the importers read contain everything you ever typed into those products. The importers read them in-memory and never extract them to disk, but the zip itself sits wherever you downloaded it — store it somewhere private or delete it after importing.
- **The one-line installer is readable.** `install.ps1` is ~80 lines and does three things: get the repo, run `setup.ps1`, run `doctor.ps1`. Piping a URL to `iex` is a trust decision. Prefer to inspect first? Save it, read the saved copy, run that same copy: `irm <url> -OutFile install.ps1`, open it, then `.\install.ps1`.

---

## What this is NOT

- **Not a product.** No sales, no paid tier, no SaaS.
- **Not fully cross-platform yet.** Windows-first. On Mac, the importers, curation, and corpus-ask run under PowerShell 7 (`install.sh`); the live capture hook and the scheduled backup are still Windows-only. Linux untested. PRs welcome.
- **Not a replacement for proper observability.** This is your *prompt* history, not your *work* history. It doesn't know what code you shipped or what worked.
- **Not stable yet.** v0.1. Schemas may change. Read the commits.

---

## Contributing

Help wanted, especially:

- **Mac/Linux hardening.** The pwsh path (`install.sh`) is experimental — real-world testing, a `pwsh`-based capture hook, and a launchd/cron backup equivalent.
- **Localized Gemini imports.** The Takeout importer assumes the English `Prompted ` activity prefix; a locale prefix table would fix non-English accounts.
- **Heuristic improvements.** Better default buckets, smarter regex, examples of project-specific configs.
- **Web UI.** A minimal localhost FastAPI/Express app that renders the corpus and exposes `corpus-ask` as a chat interface.
- **Tests.** `tests/run-tests.ps1` covers the importers, curate integration, and security regressions on PS 5.1 and PS 7. Coverage for the hook, backup, and corpus-ask paths would be valuable.

Open an issue, send a PR, or fork it and tell me what you built.

---

## License

MIT. See [LICENSE](./LICENSE).

---

## Acknowledgments

Built on top of behavior that was already in your tools. OpenAI invented `~/.codex/history.jsonl`. Anthropic shipped `UserPromptSubmit` hooks in Claude Code. This repo is the layer that turns both into something queryable. Credit where it's due.
