# Broker — opt-in tmux wake delivery

The loop's default waiting is a recurring deadline: each side arms `watch.sh`
and pays a wake when it expires.
The broker is an opt-in alternative for Linux sessions: one small process
watches the session's mailbox files with inotify and types a one-line pointer
into the recipient's registered pane the moment a mailbox changes.
Both sides then write their files and **yield** — no recurring watcher, no
idle model turns.

**The files stay the source of truth.**
The broker never carries content; its messages are pointers like
`prl: your inbox was updated - read <session>/members/worker/in`.
If the broker dies, nothing is lost: the task and the report are still the
files, and `watch.sh`/`status.sh` work exactly as before.

## Opt-in

With the broker not running, the session behaves exactly as documented in
[SKILL.md](SKILL.md) — nothing here changes that.
Start it once the session and its roster exist:

```
scripts/broker.sh start --session /tmp/prl-demo
```

Run it from inside any pane of the tmux server holding the team (it inherits
that server's socket from `$TMUX`), or from outside with an explicit
`--socket /tmp/tmux-<uid>/default`.
One broker per session; a second start is refused.

```
scripts/broker.sh status --session /tmp/prl-demo   # running? what is pending?
scripts/broker.sh log --session /tmp/prl-demo      # what the broker has done
scripts/broker.sh stop  --session /tmp/prl-demo    # back to watch.sh waiting
```

## How a round looks with the broker

- **Thinker** writes `members/<name>/in`, then ends its turn instead of arming a watcher.
- **Member** read-acks `in` (and `in-addendum`), does the work, writes `out`, then ends its turn.
- **Thinker** read-acks `out`, writes the next `in` — or not.
- Each file write wakes the other side's pane within a second or two.

On any wake: read-ack the file the message names, do the work, write your
file, yield again.
The message is not the task and not a report — the file is.

## Acknowledging a read

Typing a message is not proof of reading, and a reply is not an ack either:
the thinker may accept a final report without posting another task, and a
worker may read a task and then work longer than any nudge window allows.
So acknowledgement is explicit.  Read and ack in one operation:

```
scripts/read-ack.sh /tmp/prl-demo worker in            # member reads its task
scripts/read-ack.sh /tmp/prl-demo worker in-addendum   # and its addendum, when it has one
scripts/read-ack.sh /tmp/prl-demo worker out           # thinker reads the report
```

`read-ack.sh` opens the mailbox once, prints its content, and records the
exact revision of that snapshot (mtime in ns, size, content hash) in
`<mailbox>.ack` next to the file — so the output is precisely what was
acknowledged.  Reading and acking as two steps would be racy: if report A is
read, then atomically replaced by B before a separate ack runs, the ack would
record B's revision and B would be treated as read without being read.
Binding the revision to the snapshot that was read makes that impossible.

The broker clears a pending wake only while the mailbox still matches the
recorded revision, so:

- acknowledging a final report removes the pending wake **without another
  `in` having to be posted**, and
- a file rewritten after the read no longer matches it, so **a stale ack can
  never suppress a newer revision** — the newer write re-arms the wake.

A wake that is not acknowledged is re-nudged (twice, through the same
guarded send as everything else), then the stall is reported to the other
side.  The ack window is 10 minutes by default;
`PRL_BROKER_ACK_TIMEOUT_SECONDS` shortens it for tests.

## What the broker keeps track of

- **Mailbox revisions** (mtime + size + content hash), so a rewrite is never missed and an unchanged file never re-wakes.
  On startup it reads what is already on disk and wakes for work that was posted while it was down — an already-posted unread task or report is caught, not dropped.
- **Acknowledgement.**
  A typed message is not proof of reading.
  A wake is acknowledged only by a `read-ack.sh` of the exact revision that was read (see above); until then the wake stays pending, and after 10 minutes without an ack the broker re-nudges (twice), then tells the other side the recipient has not acknowledged and to check the pane.
- **Pending work.**
  If the recipient is mid-turn, its input line is occupied, or a send cannot be confirmed, the wake is kept and retried with backoff.
  Busy panes are deferred without limit (a long build is not a failure); unconfirmed sends are retried up to 10 times, after which the failure is reported to the other side and the work stays in the mailbox files.
  Related writes to the same recipient coalesce into one wake.
- **State across restarts.**
  All of the above lives in `<session>/broker/state.json`; stopping and starting the broker neither loses pending wakes nor re-wakes for work already acknowledged.

Every decision is written to `<session>/broker/broker.log`, and `broker.sh
status` prints the pending state even when the broker itself is down.

## Safety — same rules as the rest of the skill

The broker only reaches panes registered in `roster.tsv` or `session.env`.
**Every automatic send — the initial wake, a re-nudge, and a failure notice —
takes the same guarded path**: run the pre-send checks, then type the
pointer.  Nothing is ever typed into a shell or over unsent text, and a
re-nudge that cannot be sent is held back, not counted, so a recipient is
never nudged twice for one nudge.

Before typing into a pane it checks, in order:

1. the pane still exists,
2. it is not at a shell prompt (the agent exited; typing would run the wake as a command),
3. its `@prl_member` tag still names the member addressed,
4. the pane's process is the one registered for it (pane pid + process start time, so a replaced agent is not woken as if it were the old one),
5. for members, the pane is running the agent recorded in the roster,
6. for members with a registered agent identity (below), that exact process is still alive and still inside the pane,
7. its input line does not hold unsent text,
8. it is not mid-turn.

A failed check 1–6 deregisters that instance: the broker stops sending to
it, tells the other side why, and waits for a fresh `roster.sh add` /
`roster.sh brief`.  Checks 7–8 defer the wake instead: nothing is typed and
the wake is retried with backoff.
A parked codex goal (`Goal stalled`) is recognised and the thinker is told to
`roster.sh kick` it — the broker does not resume goals itself.

### Registering the agent's own process

The pane-level checks pin the pane, but a pane holds a shell that can run any
number of processes over its life.  To pin the exact process the broker may
wake, the agent registers itself once it is up, from a command it executes:

```
scripts/register-agent.sh /tmp/prl-demo worker
```

With no pid given, the script finds the agent from this shell's own ancestry:
`TMUX_PANE` (inherited from the pane's shell) names the pane, `pane_pid` gives
the pane's shell, and the agent is the pane-shell's child in the chain from
this shell up.  That is the right answer from an agent's tool shell, where
`$$` is the tool's bash and exits the moment the command finishes — it is
**not** the agent.  An explicit pid is still accepted
(`scripts/register-agent.sh /tmp/prl-demo worker 12345`) and recorded as-is.

This records the agent's pid and its `/proc` start time in
`<session>/broker/agents/<name>`.  With an identity recorded, the broker
refuses to type into the pane once that process has exited or been replaced —
an agent that went back to its shell, or was restarted as a new process of the
same binary — and tells the other side.  A pid reuse is ruled out by the
start time.  Without a registered identity the broker falls back to the
pane-level checks only.

```
scripts/register-agent.sh --forget /tmp/prl-demo worker   # normal unregister
```

## Managing the instance registry

Registration happens automatically from the roster and `session.env` on start
and whenever they change, so a replaced member (new pane, same name) is picked
up without restarting the broker.
To stop the broker sending to a member without touching the roster (for
example after restarting that agent by hand and before re-briefing it):

```
scripts/broker.sh deregister --session /tmp/prl-demo worker
```

## Limitations, stated plainly

- **Linux only** — file watching uses inotify.
- **The broker must be running for anyone to be woken.**
  Check `broker.sh status` at the start of a session.
  If it dies mid-session, the work stays in the files, but nobody gets poked until a human restarts it or falls back to `watch.sh`/`notify.sh`.
- **A wake is delivery, not comprehension.**
  The explicit ack proves the file was read, not understood; that remains the loop's job.
- **A parked codex goal is not resumed.**
  The broker flags it and points at `roster.sh kick`; it does not type `/goal resume`.
- **Agent identity is only as good as its registration.**
  The pane-level checks always apply.  The exact-process check catches an agent that has exited back to its shell or been replaced by a new process, but it cannot see an agent that was pushed out of the foreground while still alive: if a different process with the same command name takes the foreground in the same pane, the broker will type into it.  Deregister and re-brief if that happens.
- **One broker per session, one socket per broker.**
  All panes must live on the tmux server the broker was started against.
- The broker never creates, closes or resizes panes and never restarts agents.