---
name: paired-review-loop
description: Run a file-based loop where a "thinker" (reviewer/orchestrator) drives one or more helper agents — a worker that implements, plus optional testers that run things and capture evidence — and independently verifies every claim before accepting it. Use when supervising or driving other agents through multi-step work via files, when acting as the reviewing/orchestrating thinker, or when running as a worker or tester in such a loop. Members talk only through files. The human creates every pane and hands over the IDs; the skill cannot create, close or resize a pane, and can only reach the ones it was given. Triggers include "drive a worker agent", "thinker/worker", "review loop", "spawn a team of agents in tmux", or verifying another agent's work against real evidence.
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
- **Everyone, before you wait →** read **[WAITING.md](WAITING.md)**. Arming a watcher the wrong way is the most common way a session stalls, and it fails silently — you believe you are waiting and nothing will ever wake you. The right way differs per agent.
- **Claude thinker and Claude member? →** read **[CLAUDE-MESSAGING.md](CLAUDE-MESSAGING.md)**. `SendMessage` is easier than tmux and file polling. It only signals; files still carry the content. Codex and agy members are unaffected.
- **Running in tmux? →** also read **[TMUX.md](TMUX.md)** — how a human hands panes over, and how the thinker reaches a member that has gone quiet.

## Roles
- **worker** — implements. **The only member that edits the repo.**
- **tester** — runs commands and captures raw output. Makes **no verdicts**: testers are cheap hands, not cheap judgement. The thinker judges.

## Session setup (once)
`scripts/session.sh init <dir>` builds the tree — default `/tmp/prl-<id>/`, or a path the human gives:

```
<session>/
  session.env              the thinker's pane
  roster.tsv               who is on the team, their role, agent and pane
  members/<name>/in            thinker → that member: the current task
  members/<name>/in-addendum   extra work that arrived mid-task; read after in
  members/<name>/out           that member → thinker: the current report
  members/<name>/evidence/NN-topic.txt    raw proof, one file per claim
```

Every member owns its own directory and writes nowhere else in the session.

## The protocol (everyone obeys)
1. **Exchange files are overwritten each round and self-contained.** The top of the file IS the current task/verdict — never append history and bury the current ask; buried instructions stall the loop.
2. **Evidence = the exact command + its complete, unedited output + exit code**, saved to your own `evidence/NN-*.txt`. A prose summary is never proof. If something can't run, write `NOT RUN: <reason>` — never fake it.
3. **Green unit tests ≠ a working system.** Integration / a real human-run end-to-end is where regressions hide; require it before sign-off.
4. **The files are the channel. Everyone writes a file and waits on a file.** There is no other way to send content. (Between two Claude Code sessions, a `SendMessage` may ring the doorbell, but it only points at a file; see [CLAUDE-MESSAGING.md](CLAUDE-MESSAGING.md).) A message typed into someone's terminal is not part of the conversation and leaves no record.
   - **Members never type into anyone's pane.** Write your `out`, then wait on your `in`.
   - **Only the thinker touches tmux**, and only to check a quiet member is alive or to poke one that has stopped answering. See [TMUX.md](TMUX.md).
5. **Never end a turn waiting without an armed deadline.** Waiting means a watcher is running; believing you are waiting is not waiting.

   ```
   # thinker — every member's report, quote the pattern
   scripts/watch.sh '<dir>/members/*/out' --interval 15 --timeout 1800 --session <dir>
   # member — your own next task
   scripts/watch.sh <dir>/members/<you>/in --interval 15 --timeout 1800
   ```

   Both outcomes exit `0`; the first word of its output is `CHANGED` or `TIMEOUT`. Neither is an error, so a harness never announces a failure that did not happen. Keep **exactly one** watcher armed; kill it when you wake, act, then arm the next one.

   **How you arm it decides what waiting costs** — more than any deadline you pick. Claude Code: `scripts/monitor.sh` under a persistent Monitor, which is not reaped, stays armed across rounds, and speaks only on a change. Codex: foreground `watch.sh`, last action, deadline under its cap. A foreground deadline longer than the cap cannot finish, so it bills a turn every time; one night of that cost about $15 in waiting alone. See [WAITING.md](WAITING.md).
   **Never narrate a wait.** If you wake with nothing to act on, re-arm and stop — do not spend a turn saying "still nothing".
6. **On a timeout wake, check whose move it is — don't assume.** Run `scripts/status.sh <dir>`. It reads the mailbox timestamps and tells you, per member, whether that member owes a reply or *you* owe the next task. The stall this prevents is both sides believing the other owes something, and you cannot detect that from memory: your memory is the part that is wrong.
7. **Every turn must either advance the work or block. Never spend one reporting state.**
   - Unfinished work still authorised? **Continue it.** Nothing new arriving does not mean you are blocked — it means nothing has changed and your existing task still stands.
   - Round genuinely finished, or genuinely blocked? Write your file, then **block on a watcher**. That blocking call is what absorbs a harness that would otherwise hand you turn after turn.
   - Neither of those? You have nothing to say. A turn that says "no change", "still waiting" or "no new instructions" costs money to tell somebody what they could have assumed.
8. **Owing somebody a reply is not a state you may end a turn in.** The commonest stall in practice is not a member going quiet — it is the thinker reading a report and stopping, because reading felt like the end of the round. It is the middle. Review, write the next `in`, confirm it started, and only then wait.
9. **Waking is not reading.** Whoever wakes you, the thinker reads **every** member's `out` — several can report while it is busy, and answering only the last one to ring silently drops the rest.
10. **New work mid-task goes in `in-addendum`, never into `in`.** Rule 1 makes `in` the current task, overwritten each round — so while a member is working, overwriting `in` destroys the task it is executing and appending buries it. When more work arrives before the member has reported:
   - Write it to `<session>/members/<name>/in-addendum`.
   - The member reads `in-addendum` **after** finishing `in`, never instead of it, and deletes it once folded into that round's `out`.
   - Anything that changes the current task rather than adding to it is not an addendum: let the member finish, then write a fresh `in`.

   `watch.sh` on `<dir>/members/<you>/in*` picks up both.

## Quick start
- **Human:** open a pane per member, start the agent you want in each, and hand the thinker the pane IDs. The skill cannot make panes and will not touch one you have not registered.
- **Thinker:** `scripts/session.sh init /tmp/prl-demo`; `scripts/session.sh register /tmp/prl-demo thinker`; then per member

  ```
  scripts/roster.sh add   /tmp/prl-demo worker worker %180 /path/to/repo 'claude --model claude-sonnet-5'
  # write the first task to /tmp/prl-demo/members/worker/in
  scripts/roster.sh brief /tmp/prl-demo worker
  ```
- **Member:** read your `in`; do the task; write `evidence/NN-*.txt` + `out`; then arm `scripts/watch.sh <session>/members/<you>/in --timeout 1800` the way your harness tracks background commands (see [WAITING.md](WAITING.md)) and end your turn. Writing `out` **is** how you reply — don't also try to type at the thinker.
