---
name: paired-review-loop
description: Run a two-agent file-based loop where a "thinker" (reviewer/orchestrator) drives a "worker" (implementer) through a plan and independently verifies every claim before accepting it. Use when supervising or driving another agent through multi-step work via files, when acting as the reviewing/orchestrating thinker, or when running as the worker in such a loop. Under tmux the thinker can spawn the worker's pane and both sides wake each other instantly. Triggers include "drive a worker agent", "thinker/worker", "review loop", "spawn a worker agent in tmux", or verifying another agent's work against real evidence.
---

# paired-review-loop

Two agents, one filesystem. A **thinker** (capable/expensive model — reviews, verifies, gates, escalates) drives a **worker** (cheaper model — implements and proves it). They exchange plain files. The thinker trusts nothing: it verifies every worker claim against code and raw evidence before accepting.

The split is **verify vs. diagnose**: the thinker checks claims and reports symptoms; the worker finds causes and fixes them. A thinker that debugs a fresh defect itself has spent the expensive model on the cheap model's job — it only steps in after the worker has failed the same problem 2–3 times.

## When to use
- You're asked to drive/supervise another agent through a plan, or to rigorously review a worker's work.
- You're the worker, asked to implement tasks and prove them.

## Pick your role
- **Thinker / reviewer / orchestrator →** read **[THINKER.md](THINKER.md)**.
- **Worker / implementer →** read **[WORKER.md](WORKER.md)**.
- **Running in tmux? →** also read **[TMUX.md](TMUX.md)** — instant wake-up instead of polling, and the thinker can start the worker itself.

## Session setup (once)
Use a session dir — default `/tmp/prl-<id>/`, or a path the human gives — with an `evidence/` subdir. `scripts/session.sh init <dir>` creates it. Fixed files:
- `<session>/thinker.out` — thinker → worker: the **current** instruction/verdict.
- `<session>/worker.out` — worker → thinker: the current report/index.
- `<session>/evidence/NN-topic.txt` — the worker's raw proof, one file per claim.
- `<session>/session.env` — pane IDs and the worker's command, when running under tmux.

## The protocol (both sides obey)
1. **Exchange files are overwritten each round and self-contained.** The top of the file IS the current task/verdict — never append history and bury the current ask; buried instructions stall the loop.
2. **Evidence = the exact command + its complete, unedited output + exit code**, saved to `evidence/NN-*.txt`. A prose summary is never proof. If something can't run, write `NOT RUN: <reason>` — never fake it.
3. **Green unit tests ≠ a working system.** Integration / a real human-run end-to-end is where regressions hide; require it before sign-off.
4. **Write your file, then signal.** Two transports, and the signal is always a pointer — never the content:
   - **In tmux:** ring the counterpart's pane with `scripts/notify.sh <pane-id> 'prl: worker.out updated - read /tmp/prl-demo/worker.out'`, then end your turn and arm nothing. Its exit code tells you if it landed. See [TMUX.md](TMUX.md).
   - **Otherwise:** block on the counterpart's file with `scripts/watch.sh <file> [interval_s=60]`, backgrounded. It exits when the file changes and your harness re-invokes you. Keep **exactly one** watcher armed.

   Either way the files are the record, so a human relaying between two chats that share the filesystem still works.

## Quick start
- **Thinker:** `scripts/session.sh init /tmp/prl-demo`; write the first task to `/tmp/prl-demo/thinker.out`; start the worker with `scripts/spawn-worker.sh --session /tmp/prl-demo --cmd 'claude'` (or by hand, then `scripts/watch.sh /tmp/prl-demo/worker.out &`).
- **Worker:** read `thinker.out`; do the task; write `evidence/NN-*.txt` + `worker.out`; then notify the thinker's pane — or `scripts/watch.sh /tmp/prl-demo/thinker.out &` if there is no tmux.
