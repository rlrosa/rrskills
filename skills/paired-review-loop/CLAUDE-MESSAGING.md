# Claude to Claude: use the message framework

Read this only for the **claude-claude** pairing: a Claude Code thinker controlling a Claude Code member, both on the same machine.
For **claude-agy** (Claude thinker, agy member), **claude-codex** (Claude thinker, codex member) or any other pairing, ignore this file and use [TMUX.md](TMUX.md) and [WAITING.md](WAITING.md) for that member, unchanged.

Claude Code can message another local Claude session directly with `SendMessage`, and list reachable sessions with `ListAgents`.
This is easier and cheaper than typing into a tmux pane and polling a file.
It does not replace the files.

## What carries what

- **Files carry content.** The task is in `in`, the report is in `out`, the proof is in `evidence/`.
  Rule 1 and rule 2 of the protocol still apply in full.
- **Messages are a doorbell.** A message says that a file changed and where to read it.
  Never put a task or a verdict only in a message: it leaves no record, and a human who reads the transcript sees only its first line.
- Write the first line as one self-contained sentence, for example `New task for worker in /tmp/prl-demo/members/worker/in` or `Round 3 report ready at /tmp/prl-demo/members/worker/out`.

## Setup

1. The human starts each member as a normal Claude Code session and gives it a name.
2. The thinker runs `ListAgents`. The name in each row is the address.
3. Register the member in the roster as usual (`scripts/roster.sh add ...`) so `status.sh` and the file layout still work.
4. Write the first task to `members/<name>/in`, then send `SendMessage {to: "<name>", message: "New task in <path>/in"}`.
   Use this instead of `roster.sh brief` and `roster.sh kick` for this member.

## Waiting

- **Thinker:** after sending, pass `notify_when_idle: true` on that send (or send once with no `message` to only subscribe).
  You get one notice when the member goes idle, and you read its `out` then.
  Do not poll `ListAgents`, do not send "are you done?", and do not run a `watch.sh` loop for this member.
- **Member:** write `out`, then send one message to the thinker with the `from` address of the message that gave you the task.
  Then end your turn. You do not need a `watch.sh` on `in`; the next task arrives as a message.
- Rule 9 still holds: after any wake, read every member's `out`, not only the one that rang.

## Limits you must plan for

- A successful send means the message reached the session, not that the session read it.
- Messages are delivered at the receiver's next tool round, so a busy member sees yours late.
- A session in a different permission mode holds messages for its user to approve, and may let them expire.
  Do not ask a peer to do something your own permissions would block; route it to the human.
- Silence is not agreement and not failure. Run `scripts/status.sh <dir>` to see whose move it is.

## Fallback to tmux

If a send says the session has no inbox, or a member has not answered after one round, use the tmux path for that member: `scripts/status.sh`, then `scripts/roster.sh kick`.
Only the thinker touches tmux, and only for a pane the human registered.

## Mixed teams

Each member uses the channel that fits its agent.
A Claude thinker with one Claude worker and one codex tester uses messages for the worker and the tmux plus watcher flow for the tester.
The file layout is the same either way.
