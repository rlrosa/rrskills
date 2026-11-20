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
- **Member** reads `in` (and `in-addendum`), does the work, writes `out`, then ends its turn.
- Each file write wakes the other side's pane within a second or two.

On any wake: read the file the message names, do the work, write your file,
yield again.
The message is not the task and not a report — the file is.

## What the broker keeps track of

- **Mailbox revisions** (mtime + size + content hash), so a rewrite is never missed and an unchanged file never re-wakes.
  On startup it reads what is already on disk and wakes for work that was posted while it was down — an already-posted unread task or report is caught, not dropped.
- **Acknowledgement.**
  A typed message is not proof of reading.
  A wake owed to a member counts as acknowledged only when that member's `out` gets a newer revision; a wake owed to the thinker only when the member's `in` does.
  Until then the wake stays pending, and after 10 minutes without an ack the broker re-nudges (twice), then tells the other side the recipient has not acknowledged and to check the pane.
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
Before typing into a pane it checks, in order:

1. the pane still exists,
2. it is not at a shell prompt (the agent exited; typing would run the wake as a command),
3. its `@prl_member` tag still names the member addressed,
4. the pane's process is the one registered for it (pane pid + process start time, so a replaced agent is not woken as if it were the old one),
5. for members, the pane is running the agent recorded in the roster,
6. its input line does not hold unsent text,
7. it is not mid-turn.

A failed check 1–5 deregisters that instance: the broker stops sending to it,
tells the other side why, and waits for a fresh `roster.sh add` /
`roster.sh brief`.
A parked codex goal (`Goal stalled`) is recognised and the thinker is told to
`roster.sh kick` it — the broker does not resume goals itself.

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
  Only the recipient's reply file proves it was read; that is what the ack tracking above is for.
- **A parked codex goal is not resumed.**
  The broker flags it and points at `roster.sh kick`; it does not type `/goal resume`.
- **Agent identity is the pane's process, not the agent's own pid.**
  A build the agent runs in the foreground does not change the identity, but the broker cannot see an agent that is swapped in place inside the same pane — deregister and re-brief if that happens.
- **One broker per session, one socket per broker.**
  All panes must live on the tmux server the broker was started against.
- The broker never creates, closes or resizes panes and never restarts agents.