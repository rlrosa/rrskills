---
name: paired-review-loop
description: Run a file-based loop where a "thinker" (reviewer/orchestrator) drives one or more helper agents — a worker that implements, plus optional testers that run things and capture evidence — and independently verifies every claim before accepting it. Use when supervising or driving other agents through multi-step work via files, when acting as the reviewing/orchestrating thinker, or when running as a worker or tester in such a loop. Under tmux the thinker can spawn each member's pane with the agent and model you choose (claude, codex, agy) and everyone wakes each other instantly. Triggers include "drive a worker agent", "thinker/worker", "review loop", "spawn a team of agents in tmux", or verifying another agent's work against real evidence.
---

# paired-review-loop

Several agents, one filesystem. A **thinker** (capable/expensive model — reviews, verifies, gates, escalates) drives a team of cheaper members and trusts none of them: it verifies every claim against code and raw evidence before accepting it. They exchange plain files.

The split is **verify vs. diagnose**: the thinker checks claims and reports symptoms; the worker finds causes and fixes them. A thinker that debugs a fresh defect itself has spent the expensive model on the cheap model's job — it only steps in after the worker has failed the same problem 2–3 times.

The team is whatever you ask for. A single worker is the common case; a worker plus two or three testers parallelises the slow part. Each member is a **separate agent CLI of your choosing** — `claude --model …`, `codex`, `agy --dangerously-skip-permissions` — with its own context, cost and permissions.

## When to use
- You're asked to drive/supervise other agents through a plan, or to rigorously review their work.
- You're a worker, asked to implement tasks and prove them.
- You're a tester, asked to run something and capture what happened.

## Pick your role
- **Thinker / reviewer / orchestrator →** read **[THINKER.md](THINKER.md)**.
- **Worker / implementer →** read **[WORKER.md](WORKER.md)**.
- **Tester →** read **[TESTER.md](TESTER.md)**.
- **Running in tmux? →** also read **[TMUX.md](TMUX.md)** — instant wake-up instead of polling, and the thinker can start the whole team itself.

## Roles
- **worker** — implements. **The only member that edits the repo.**
- **tester** — runs commands and captures raw output. Makes **no verdicts**: testers are cheap hands, not cheap judgement. The thinker judges.

## Session setup (once)
`scripts/session.sh init <dir>` builds the tree — default `/tmp/prl-<id>/`, or a path the human gives:

```
<session>/
  session.env              the thinker's pane
  roster.tsv               who is on the team, their role, agent and pane
  members/<name>/in        thinker → that member: the current task
  members/<name>/out       that member → thinker: the current report
  members/<name>/evidence/NN-topic.txt    raw proof, one file per claim
```

Every member owns its own directory and writes nowhere else in the session.

## The protocol (everyone obeys)
1. **Exchange files are overwritten each round and self-contained.** The top of the file IS the current task/verdict — never append history and bury the current ask; buried instructions stall the loop.
2. **Evidence = the exact command + its complete, unedited output + exit code**, saved to your own `evidence/NN-*.txt`. A prose summary is never proof. If something can't run, write `NOT RUN: <reason>` — never fake it.
3. **Green unit tests ≠ a working system.** Integration / a real human-run end-to-end is where regressions hide; require it before sign-off.
4. **Write your file, then signal.** Two transports, and the signal is always a pointer — never the content:
   - **In tmux:** ring the recipient with `scripts/notify.sh --session <dir> --member <name> 'prl: …'`, then end your turn and arm nothing. Address by **member name, not pane ID** — that makes the pane prove who it is first. Its exit code tells you if it landed. See [TMUX.md](TMUX.md).
   - **Otherwise:** block on the counterpart's file with `scripts/watch.sh <file>… [--interval 60]`, backgrounded. It exits when any watched file changes and your harness re-invokes you. Keep **exactly one** watcher armed.

   Either way the files are the record, so a human relaying between chats that share the filesystem still works.
5. **Waking is not reading.** Whoever wakes you, the thinker reads **every** member's `out` — several can report while it is busy, and answering only the last one to ring silently drops the rest.

## Quick start
- **Thinker, one worker:** `scripts/session.sh init /tmp/prl-demo`; write the task to `/tmp/prl-demo/members/worker/in`; then
  `scripts/spawn-member.sh --session /tmp/prl-demo --name worker --role worker --cmd 'claude'`.
- **Thinker, a whole team:** write a spec and run
  `scripts/spawn-team.sh --session /tmp/prl-demo --spec team.txt --cwd /path/to/repo`.

  ```
  # name      role     agent
  worker      worker   claude --model claude-sonnet-5
  tester-1    tester   codex
  tester-2    tester   agy --dangerously-skip-permissions
  ```
- **Member:** read your `in`; do the task; write `evidence/NN-*.txt` + `out`; then ring the thinker — or `scripts/watch.sh <session>/members/<you>/in &` if there is no tmux.
