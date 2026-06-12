# corpus-engine

> **Every Codex CLI user has thousands of their own prompts sitting on disk right now. Most don't know.**
> This is the engine I built to capture them, classify them, and ask questions of them in plain English. It also captures every prompt I send to Claude Code, across every project, automatically. Yours can too.

```
You -> Claude Code or Codex CLI -> this engine -> a queryable record of how you think
```

**v0.1, Windows-only, by [@marcdlagarde](https://github.com/marcdlagarde).** Rough edges, no UI, opinions baked in. Mac/Linux port: help wanted (see [Contributing](#contributing)).

---

## What it does

1. **Captures** every prompt you submit to Claude Code (via a `UserPromptSubmit` hook) and every prompt you've ever sent to Codex CLI (via its built-in `~/.codex/history.jsonl`).
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

## Quickstart (5 minutes, Windows)

```powershell
git clone https://github.com/marcdlagarde/corpus-engine.git
cd corpus-engine
.\setup.ps1
```

The setup script:
- Verifies prerequisites (PowerShell, `claude` CLI, Codex history)
- Creates your corpus directory (default: `~\corpus`, override with `$env:CORPUS_ROOT`)
- Installs `AGENTS.md` into your corpus directory so future Claude/Codex agents know how to refresh and query it
- Runs a curation pass against the bundled `samples/` so you immediately see real output
- Prints the manual steps for the Claude Code hook and the optional auto-backup

After setup, the next prompt you submit to Claude Code will land in your corpus. `corpus-ask.ps1` refreshes the JSONL exports before every query by default, and `refresh.ps1` gives agents a direct way to do the same without using Claude.

---

## Layout

```
corpus-engine/
├── tools/
│   ├── log-prompt.ps1            # Claude Code UserPromptSubmit hook
│   ├── import-codex-history.ps1  # incremental Codex history.jsonl importer
│   ├── refresh.ps1               # import Codex + regenerate JSONL/markdown views
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
├── AGENTS.md                     # instructions for agents working on this engine
├── setup.ps1                     # one-time install
├── LICENSE                       # MIT
└── README.md
```

Your corpus root (`~\corpus` by default) ends up structured like this:

```
~\corpus\
├── AGENTS.md             # tells future agents how to refresh/query this corpus
├── _RAW_PROMPT_LOG.md     # Claude Code capture (firehose, append-only)
├── _raw-codex.md          # Codex CLI imports
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

---

## What this is NOT

- **Not a product.** No sales, no paid tier, no SaaS.
- **Not cross-platform yet.** PowerShell-only at v0.1. The classification heuristics and JSONL schema are portable; the capture mechanism needs a Bash equivalent for Mac/Linux. PRs welcome.
- **Not a replacement for proper observability.** This is your *prompt* history, not your *work* history. It doesn't know what code you shipped or what worked.
- **Not stable yet.** v0.1. Schemas may change. Read the commits.

---

## Contributing

Help wanted, especially:

- **Mac/Linux port.** A Bash equivalent of `log-prompt.ps1` + Codex importer. Same JSONL schema.
- **Heuristic improvements.** Better default buckets, smarter regex, examples of project-specific configs.
- **Web UI.** A minimal localhost FastAPI/Express app that renders the corpus and exposes `corpus-ask` as a chat interface.
- **Tests.** There aren't any. A small sanity suite would be valuable.

Open an issue, send a PR, or fork it and tell me what you built.

---

## License

MIT. See [LICENSE](./LICENSE).

---

## Acknowledgments

Built on top of behavior that was already in your tools. OpenAI invented `~/.codex/history.jsonl`. Anthropic shipped `UserPromptSubmit` hooks in Claude Code. This repo is the layer that turns both into something queryable. Credit where it's due.
