# Pi — skill invocation, communication, and waiting

Use this guide when Pi is the thinker, a worker, or a tester. Read the matching
role file too; the shared mailbox protocol and evidence rules are unchanged.
Resolve `scripts/` relative to the loaded skill directory, not the worktree.

## Load and invoke the skill

For the local plugin checkout:

```bash
pi install ~/agent-plugins/.pi-package
```

If Pi already lists that package in `pi list`, do not install another copy.
Run `/reload` in an existing session, then invoke:

```text
/skill:paired-review-loop Act as the worker; read /tmp/prl-demo/members/worker/in.
```

Pi uses **`/skill:paired-review-loop`**, not Claude's `/paired-review-loop` or
Codex's `$paired-review-loop`. Text following the command becomes the request.

To try the source skill for one session without installing it, run:

```bash
pi --no-skills --skill ~/rrskills/skills/paired-review-loop
```

Use one copy per session. The source checkout and marketplace copy have the
same skill name, and loading both can select the wrong copy. A live review-loop
session also records which scripts own it; keep using that copy throughout the
session.

## Communicate through files

Pi has no built-in Claude `SendMessage` or persistent Monitor tool, and this
workflow does not require an extension. Do not use Claude-specific messaging or
Codex's `/goal` commands in a Pi session.

- **Thinker:** write each member's `in`, read every `out`, and verify the evidence.
- **Worker/tester:** read your `in` and `in-addendum`, write evidence and `out`,
  then wait on your inbox. Do not type into the thinker's pane.
- **Thinker nudging an idle member:** use the shared `scripts/notify.sh` and
  `scripts/roster.sh kick` helpers, after writing the task. A nudge only points
  at the mailbox; it never carries the task itself.

The human still creates and starts every agent pane. Register a Pi member with
its actual executable and flags, for example:

```bash
scripts/roster.sh add /tmp/prl-demo worker worker %180 /path/to/repo 'pi --model provider/model'
scripts/roster.sh brief /tmp/prl-demo worker
```

`brief` recognizes `pi` and an absolute executable path ending in `/pi`, and
selects `/skill:paired-review-loop`. Do not register a shell wrapper as `pi`
unless that wrapper actually launches Pi.

## Wait in a foreground bash tool call

Pi's built-in `bash` tool waits for the command to finish and has no default
timeout. Set an explicit tool timeout **longer** than `watch.sh`'s deadline so
the script, not the tool, decides when an idle wait ends.

Thinker tool arguments:

```json
{
  "command": "<skill-directory>/scripts/watch.sh '/tmp/prl-demo/members/*/out' --interval 15 --timeout 1800 --session /tmp/prl-demo",
  "timeout": 1860
}
```

Worker/tester tool arguments:

```json
{
  "command": "<skill-directory>/scripts/watch.sh '/tmp/prl-demo/members/worker/in*' --interval 15 --timeout 1800",
  "timeout": 1860
}
```

Replace `<skill-directory>` with the loaded skill's absolute directory. Keep
exactly one mailbox watcher, and make the blocking call your last action while
waiting. Do not add `&`, `nohup`, or `setsid`: a detached watcher cannot give Pi
a new turn. Do not start the never-ending `monitor.sh` as a foreground call;
it is intended for a harness with a persistent Monitor tool.

When the call returns, the watcher has exited. On `CHANGED`, read the mailbox;
the thinker reads every member's `out`, not just the one named in the output.
On `TIMEOUT`, run `scripts/status.sh` and act on whose move it is before waiting
again. Do not narrate an unchanged wait.

If the tool reports a timeout instead of the script printing `TIMEOUT`, the
watcher was cut off. Increase the tool timeout, or shorten the script deadline
if your Pi integration imposes a lower limit. If you cannot keep a foreground
call open, report that you are stopped rather than claiming a watcher will
wake you later.
