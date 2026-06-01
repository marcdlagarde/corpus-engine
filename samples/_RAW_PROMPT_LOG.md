# Raw Prompt Log (sample)

This is a SYNTHETIC sample. Real prompts from a real user would land here if
you wired up the Claude Code UserPromptSubmit hook. The entries below are
hand-written to demonstrate what the parser handles + give the curation
script something to chew on for first-time visitors.

Run `tools/curate.ps1 -CorpusRoot samples` to see the pipeline produce
buckets, sessions, and JSONL exports from this fake data.

---


## 2026-04-12T09:14:33-04:00
> cwd: /home/user/projects/sample-app
> session: 7a1b2c3d

How do we handle the case where the user submits two API requests within the same millisecond? I'm worried about deduplication but I don't want to add too much state.

---


## 2026-04-12T09:16:51-04:00
> cwd: /home/user/projects/sample-app
> session: 7a1b2c3d

actually wait, this is a strategy question more than a code question. The reason I'm asking is because I think the underlying issue is that we don't have a clear contract for what an idempotent request looks like. Should the client send an idempotency key? Or do we hash the request body? I keep going back and forth and I think I need to just pick one.

---


## 2026-04-12T09:22:07-04:00
> cwd: /home/user/projects/sample-app
> session: 7a1b2c3d

ok pick idempotency keys. simpler. close the thread.

---


## 2026-04-14T14:33:12-04:00
> cwd: /home/user/projects/sample-app
> session: 8d4e5f6a

I want to write a LinkedIn post about how I approach AI-assisted coding. The angle I keep coming back to is that the model doesn't fail; the brief does. Could you help me outline three concrete examples from this week where I gave a vague instruction and got predictable bad output?

---


## 2026-04-14T14:45:09-04:00
> cwd: /home/user/projects/sample-app
> session: 8d4e5f6a

good. let's expand example 2. that's the strongest one because it shows the difference between "fix the bug" and "fix the bug, don't touch the migration, cite the line numbers you changed." Different posts entirely.

---


## 2026-04-21T20:02:44-04:00
> session: 9b3c4d5e

so the data center thing keeps showing up in my drafts. I think it's because the discipline of writing down "what could break tonight" is exactly what's missing from how most people brief AI. you know what I mean? like, you don't ship a config change to prod at 3am without a rollback plan, but you'll let an agent rewrite half your codebase on vibes.

---


## 2026-04-21T20:05:18-04:00
> session: 9b3c4d5e

write me a tweet-length version of that, please

---


## 2026-04-30T11:18:55-04:00
> cwd: /home/user/projects/other-thing
> session: a2b3c4d5

quick check before i merge: did the latest change touch the email sending logic? I just want to make sure nothing got reordered there. it's the one path I really don't want subtle behavior changes in.

---


## 2026-04-30T11:30:22-04:00
> cwd: /home/user/projects/other-thing
> session: a2b3c4d5

great. merge.

---


## 2026-05-03T08:55:14-04:00
> session: e7f8a9b0

I've been thinking about how to position my newsletter. The audience is split right now between operators who care about reliability and indie hackers who care about velocity. Is there a frame that speaks to both? Or do I have to pick?

---
