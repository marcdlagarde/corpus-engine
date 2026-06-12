# Corpus Engine Agent Instructions

This repo is the public corpus-engine distribution. It is not a user's private
corpus unless they deliberately point `CORPUS_ROOT` here. Never commit real
prompt logs, secrets, runtime corpus files, or personal corpus output.

## Working On This Repo

Before code or doc edits:

1. Check `git status --short`.
2. Preserve existing local changes unless the operator explicitly asks to
   replace them.
3. Keep distribution changes generic. Do not hard-code private paths.

## Installed Corpus Query Protocol

When a user asks an agent to "ask corpus", "query corpus", or find patterns in
their prompts, the agent should use the installed corpus root, not this engine
repo, unless the user says otherwise.

In an installed corpus, `setup.ps1` writes an `AGENTS.md` file from
`templates/AGENTS.md`. That file points to the right corpus root and engine
tools path.

The intended query sequence is:

1. Run `tools/refresh.ps1` for the target corpus root. This imports new Codex
   prompts from `~/.codex/history.jsonl` and regenerates `entries.jsonl` and
   `sessions.jsonl`.
2. Read `sessions.jsonl` as the manifest.
3. Filter `entries.jsonl` by `sess`, `src`, `tags`, or body keywords.
4. Cite evidence with entry timestamps: `[ts: ISO-timestamp]`.

`tools/corpus-ask.ps1` performs the refresh step by default before invoking
Claude. If Claude CLI auth fails, agents should fall back to direct JSONL
querying instead of stopping.

## Data Surface

- `entries.jsonl`: canonical machine-readable prompt entries.
- `sessions.jsonl`: canonical machine-readable session manifest.
- `_RAW_PROMPT_LOG.md`: raw Claude Code hook capture.
- `_raw-codex.md`: raw Codex CLI import.
- `curated/` and `sessions/`: generated human-readable views.

The corpus contains prompts only. It usually does not contain assistant
responses, generated code, or proof that a prompt worked.
