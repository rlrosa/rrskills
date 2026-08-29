# tmux — spawning the team, and reaching a member that has gone quiet

Optional, and deliberately narrow. Without tmux the loop works exactly as documented in [SKILL.md](SKILL.md).

**The files are the channel. tmux is not a second one.**

Every message between the thinker and a member is a file: the thinker writes `members/<name>/in`, the member writes `members/<name>/out`, and both sides wait on those files with `scripts/watch.sh`. That is the whole protocol, and it is what makes a session re-readable afterwards.

tmux does two jobs, both of them the **thinker's**:

1. **Briefing a member** the human already started — `roster.sh brief`.
2. **Reaching a member that has stopped answering** — `notify.sh`, plus `roster.sh verify` to tell a working member from a stuck one.

**Members never use it.** A member replies by writing its `out` file and waiting on its `in`. Typing at the thinker instead leaves no record, cannot be re-read, and is silently swallowed whenever the thinker happens to be mid-turn.

## Do you have it?

You have tmux comms when a tmux server is reachable and you know the counterpart's pane ID.
`scripts/notify.sh` checks both for you and tells you which one is missing, so you do not need to probe first — just call it and read the exit code.

Your own pane ID is in `$TMUX_PANE`. Pane IDs look like `%174`, are unique across the whole tmux server, and are never reused, so one pane can address any other pane in any session or window.

## Finding the counterpart's pane

The thinker's pane lives in `<session>/session.env`:

```
PRL_SESSION_DIR='/tmp/prl-demo'
PRL_THINKER_PANE='%174'
```

Every member's pane lives in `<session>/roster.tsv`:

```
# name     role     agent                          pane   cwd
worker     worker   claude --model claude-sonnet-5 %180   /home/rrosa/repo
tester-1   tester   codex                          %181   /home/rrosa/repo
tester-2   tester   agy --dangerously-skip-permissions %182 /home/rrosa/repo
```

- You fill both in: `session.sh register` for the thinker's own pane, `roster.sh add` for each member's.
- Started by hand? The thinker runs `scripts/session.sh register <dir> thinker`; each member runs `scripts/roster.sh add <dir> <name> <role> $TMUX_PANE $PWD '<agent>'`.
- Read one field with `scripts/roster.sh get <dir> worker pane`.

### The roster is a cache, not the truth

Every member's pane is also **tagged with its own identity** — `@prl_session`, `@prl_member`, `@prl_role`, `@prl_cmd` — as tmux pane options. Two consequences worth relying on:

- **A stale roster cannot misdeliver.** `roster.sh resolve` (which `notify.sh --member` uses) checks the pane's tag against the name you asked for and refuses if they disagree.
- **A lost roster is recoverable.** `scripts/roster.sh sync <dir>` rebuilds the whole file by scanning tagged panes across the tmux server, agent command and all. Deleting `roster.tsv` is survivable; the panes still know who they are.

`scripts/roster.sh verify <dir>` prints one line per member — `OK`, `GONE`, `EXITED`, `MISMATCH` — plus `UNLISTED` for tagged panes missing from the file. Run it whenever a notify fails or a member goes quiet.

## Poking a member that has gone quiet

For the thinker only, and only after `status.sh` says that member owes a reply and `roster.sh verify` says its pane is alive.

```
scripts/notify.sh --session <dir> --member <name> <message>   # preferred
scripts/notify.sh --session <dir> --role tester <message>     # every tester
scripts/notify.sh <pane-id> <message>                         # raw, unchecked
```

**This is a nudge, never a task.** The message says "look at your inbox" and nothing more; the task itself is already in the file. Anything typed into a terminal is gone the moment it scrolls, and is silently swallowed if that agent is mid-turn.

**Address by name, not by pane ID.** The named forms make the pane prove who it is first; a raw `%N` you cached earlier is how a task ends up in the wrong agent's terminal.

**Never hand-roll `tmux send-keys` yourself.** It looks like a one-liner and it is not. Two failure modes bite agents that try, and both look like success:

- **The Enter goes missing.** You type the text, the characters appear, and the message sits in the input box unsent — forever. A TUI that has not started reading input swallows the Enter, and a screen that shows your text is not proof it was submitted. `notify.sh` presses Enter until the input box actually empties.
- **A placeholder is mistaken for someone else's message.** Agent TUIs show greyed-out suggestions in an empty input box — codex offers `Write tests for @filename` — and an agent that reads the screen to check "is the box free?" sees text and refuses to send. Do not check the screen for that. **Check the cursor**: a placeholder leaves it parked at the start of the box, real characters push it along.

  Measured on an idle codex pane: placeholder showing, `#{cursor_x}` = 2. After typing 11 characters, 13. After `C-u`, back to 2 with the placeholder redrawn. The screen changed every time; only the cursor told the truth.

`notify.sh` uses the cursor for both checks and falls back to the screen only when a TUI does not move it.

### What is *not* going wrong, measured

Two explanations for this get invented repeatedly. Both are wrong, and believing them sends you off tuning things that do not matter:

- **"`send-keys 'text' Enter` in one call swallows the newline."** It does not. Sent to a program that reads raw bytes, the one-call and two-call forms deliver exactly the same thing — `hello-one\r` and `hello-two\r`. tmux also does not wrap either in bracketed-paste markers.
- **"Use `C-m` instead of `Enter`."** They are the same byte. Both send `\r`.

What actually matters is the **gap** between the text and the carriage return, and whether the TUI was ready to read at all. That is why `notify.sh` sleeps `PRL_SEND_DELAY` (0.3s) between them and then presses Enter again until the input box empties — not because it uses two calls.

So if you find yourself reasoning about `C-m`, call counts or paste brackets, stop: use `notify.sh` or `roster.sh kick` and let the retry loop do it.

### A typed-but-unsent nudge looks exactly like a delivered one

This is the part worth internalising. The characters appear on screen either way, so **seeing your text is not evidence it was sent**. The message can sit in the input box indefinitely while the pane looks perfectly normal, and the downstream symptom is a member that never armed a watcher and a "lapsed watcher" that was never armed in the first place.

Verify by whether the agent is *doing something*: `roster.sh kick` waits for the pane to start working and refuses to report success otherwise. Reading the pane yourself, the human-legible version of the same signal is the cost and context counters moving — a model that has not received your message has not spent anything.

Write your file first, then notify — otherwise the recipient wakes up and reads the previous round.

Keep the message to one line that names the file to read:

```
prl: your inbox was updated - read /tmp/prl-demo/members/worker/in
prl: worker reported - round 3 + evidence/04-*.txt
```

**Start the message with `prl:`.** Agent TUIs read a leading `/`, `#` or `!` as a mode switch — slash command, memory, shell — so a nudge starting with one of those gets acted on instead of read.

### Exit codes — each means a different next move

| Code | Meaning | What to do |
| --- | --- | --- |
| `0` | Sent. `ACCEPTED` = it is working now; `DELIVERED` = keys landed but it went idle; `QUEUED` = could not be confirmed | Watch its `out` file, not this line. |
| `10` | tmux unreachable | Read which of the three reasons it printed. **Carry on either way** — the task is already in the file. |
| `11` | No such pane | The counterpart is gone. Tell the human. |
| `12` | Pane is at a shell prompt | Its agent has exited. Nothing was sent. Tell the human; do not retry. |
| `13` | Keys sent, pane did not react | Treat as unreliable: arm a watcher as well, and say so. |
| `14` | The pane says it is someone else | Roster is stale. Nothing was sent. `roster.sh verify`, then fix it before sending to anyone. |
| `15` | The pane holds unsent text | A human is probably mid-sentence. Nothing was sent, because Enter would submit their fragment too. Wait, or `--force`. |
| `2` | Bad usage (multi-line message) | Fix the call. |

Three of these stop a send rather than report one, and all fail *before* typing anything:

- **`12`** — a pane whose agent has exited is a live shell, and typing a message into a shell runs it as a command. `notify.sh` checks the pane's foreground command first.
- **`14`** — the pane's `@prl_member` tag does not match the member you addressed. Something reused or retagged that pane, so the roster is lying about where that agent is.
- **`15`** — the target's input line already holds unsent text. `notify.sh` types its message and presses Enter, so on a pane where a human is midway through a sentence that Enter would submit their unfinished line along with the nudge, starting work on an instruction nobody meant to send. There is no safe way to type around it, so it refuses.

With `--role`, each member is reported separately and the exit code is the worst one seen, so one dead tester does not hide the others succeeding.

A delivered nudge proves the keystrokes landed, not that the recipient understood them. Only its reply on its own file proves that.

### Losing the poke does not block the loop

This is worth being emphatic about, because getting it wrong wastes a whole session.

`notify.sh` is an **optimisation**. It makes a member notice its inbox in seconds instead of on its own deadline. If it fails — any exit code, any reason — the task is still written, the member is still watching its inbox, and it will still pick the work up.

So when a poke fails: note it, carry on, and raise it with the human only if that member then stays quiet past its deadline. Stopping the session to have tmux repaired trades a few minutes of latency for however long it takes the human to notice you are waiting.

## Waiting

Write your file, arm a watcher, end your turn.

```
# thinker: every member's report. QUOTE the pattern.
scripts/watch.sh '/tmp/prl-demo/members/*/out' --interval 15 --timeout 540

# member: your own next task
scripts/watch.sh /tmp/prl-demo/members/worker/in --interval 15 --timeout 540
```

Both outcomes exit `0`; the first word of its output tells you which — `CHANGED <file>` or `TIMEOUT <seconds>`. Keep exactly one armed, and kill it when you wake before arming the next.

**Quote the pattern.** On round one no `out` file exists, so an unquoted `*/out` finds nothing to expand and the shell passes the literal `*` through as a filename that can never appear — the watcher then sits there while the worker reports, and only the deadline eventually frees it. `watch.sh` re-expands patterns itself on every poll, which fixes the unquoted case too and means a member who joins mid-wait is picked up as well; quoting just makes it unambiguous.

Waking is still not reading: whichever file fired, the thinker reads **every** member's `out`, because others may have reported while it was busy.

### The four ways a loop stalls

Every one of them ends with both sides believing the other owes a reply. Notice that a watcher with no deadline only helps with the first two — in the last two *nothing changes*, so a change-triggered wake never fires.

| | What happened | What breaks it |
| --- | --- | --- |
| Someone rang, and the ring failed | `notify` exit 13, or the message queued and was never acted on | The recipient's deadline |
| Someone wrote but never rang | The nudge was skipped entirely | The recipient's deadline |
| Someone believes they handed off but wrote nothing | No file changed at all | The other side's deadline + `status.sh` |
| The recipient woke, read, and decided there was nothing to do | Both now think it is the other's move | Either side's deadline + `status.sh` |

**When a wait ends with `TIMEOUT`, do not assume you are still waiting.** Run `scripts/status.sh <session>`. It compares each member's `in` against its `out` and tells you who actually owes what:

```
member       owes       since  pane      note
worker       thinker    3m     OK        replied; you owe the next task
tester-1     tester-1   22m    WAITING   frozen with its task unanswered
```

`in` newer than `out` means that member owes a reply; `out` newer than `in` means the thinker owes the next task. It exits `1` when something has been owed longer than `PRL_STALL_AFTER` (default 600s) or a pane is not `OK`.

Then act on what it says: re-ring whoever owes, or — if it says *you* owe the next task — write it. After two unanswered nudges for the same round, stop nudging and tell the human which member is stuck and for how long.

## Setting the team up

**You create the panes. The skill never does.**

It has no way to: nothing in `scripts/` can split a window, open one, close one or resize anything. The only tmux verbs left are reading pane state, tagging a pane, and typing into one. So a session can only ever touch panes you handed it, and it cannot rearrange the terminal you are working in.

The setup is three steps, and only the middle one is the skill's.

**1. You make the panes and start the agents.** However you like — splits, windows, separate sessions, whatever suits your layout. Start each agent with the model and permission flags you want. Note each pane's ID:

```
tmux list-panes -a -F '#{pane_id} #{pane_current_command} #{pane_current_path}'
```

**2. Register each one, then brief it.** Registering is what puts a pane on the allowlist; nothing outside the roster is reachable.

```
scripts/session.sh init /tmp/prl-demo
scripts/session.sh register /tmp/prl-demo thinker      # the thinker's own pane

scripts/roster.sh add   /tmp/prl-demo worker   worker %180 /path/to/repo 'claude --model claude-sonnet-5'
scripts/roster.sh add   /tmp/prl-demo tester-1 tester %181 /path/to/repo 'codex'

scripts/roster.sh brief /tmp/prl-demo worker
scripts/roster.sh brief /tmp/prl-demo tester-1
```

`brief` types one line into that member's pane telling it its role, its name, its mailbox paths and the thinker's pane, then confirms the agent actually started working. Write `<session>/members/<name>/in` **before** briefing and the member goes straight to work; leave it empty and it is told to wait instead, because an agent pointed at a file that does not exist will improvise.

**3. From then on the thinker only reads files, pokes registered members, and writes tasks.**

Every member's CLI must already have this skill installed — `./install.sh` from the repo root does that for Claude, AGY and Codex.

### What the thinker can and cannot do

| Can | Cannot |
| --- | --- |
| Read any pane's state (`roster.sh verify`) | Create a pane or window |
| Type into a **registered** member's pane | Close or resize anything |
| Tag a registered pane with its identity | Reach a pane that is not in the roster |

`notify.sh` takes no pane-ID argument at all — only `--member` and `--role` — so an unregistered pane is unreachable rather than merely discouraged.

### When a member has to be replaced

You do that too. Stand the old member down in its `in` first, then kill and recreate the pane yourself, `roster.sh add` the new pane under the same name, and `roster.sh brief` it. `roster.sh verify` will report the old row as `GONE` in between, which is the intended signal rather than something to fix silently.

## A parked codex goal is not a hung member

`roster.sh verify` will say `OK` and `status.sh` will say the pane is idle, both correctly — a member whose `/goal` has stalled is alive, healthy and deliberately not working. What it is not is reachable by an ordinary nudge.

Look for `Goal stalled (/goal resume)` in the pane footer. The fix is a new task in `in` followed by `roster.sh kick`, which sends the resume and then proves the pane started. Everything else — re-notifying, re-arming a watcher, waiting longer — does nothing at all.

## Telling a thinking member from a hung one

The hardest state to read, and the most expensive to get wrong. A hung member looks exactly like a working one: its timer keeps counting, so `roster.sh verify` reports `OK` and any "is the pane redrawing" check says yes. One member sat like that twice in a session, for 17 and 15 minutes, showing `Working (16m 34s)` the whole time — it had read its task and then done nothing.

**Four signs together mean hung, not thinking:**

1. The elapsed timer is advancing.
2. **No subprocess** — nothing it claims to be running actually exists.
3. **Context percentage unchanged** — a thinking agent consumes context; a stuck one does not.
4. **Nothing new on disk** — no output files, no evidence, no writes anywhere.

Any one alone means nothing. All four together is the signature.

**What to do:** interrupt after about 12 minutes of it. And when you replace or abandon a member, **stand it down explicitly** in its `in` — one that is merely ignored can wake up much later and fire a duplicate batch at whatever it was doing.

## Probing liveness is unreliable inside a command sandbox

Two traps that both read as facts because they reproduce every time:

- **`ps -p <pid>` reports a live detached job as dead** when run inside a sandboxed command, and correctly as running with the sandbox off. Check job liveness with the sandbox off, or you will conclude a healthy run has died.
- **Unanchored `pgrep -f` matches inside argv.** `pgrep -a -f bazel` matched four unrelated sandbox processes because `bazel.build` appeared inside a `--policy-json` argument. Anchor the pattern to the executable, or match on the process name, before concluding anything is running.

## Escape does not do what you want to a codex pane

The obvious recovery for a queued-but-unread nudge is to press Escape and retype. On a codex pane that **pauses its `/goal`**, and it then needs `/goal resume` before it will do anything — a lost cycle, and it looks like the member simply stopped.

If a nudge appears stuck in a codex pane, leave the keyboard alone and let its own wait deadline fire.

## When it does not work

- **Exit 10 saying "sandboxed", from inside a pane you can see.** Your command sandbox will not open the tmux socket, even though tmux is running and the socket is right there. Codex's workspace sandbox does this. Re-run the same command with the sandbox off or with escalated permissions.

  **Do not ask the human to restart or "expose" tmux.** One thinker did exactly that — reported the server unreachable, stopped, and waited — while tmux was running normally the whole time and the true error was `Operation not permitted` on the socket. `notify.sh` now prints tmux's own words and names the socket so this is not guessable.
- **Nudges land but nothing happens.** The counterpart is mid-turn; its harness queues the message. Wait a round before re-sending.
- **Exit 12 right after spawning.** The agent exited on startup. Look at the pane — it is still there on purpose — and check the command and its permission flags.
- **Spawn times out.** The agent never came up within 60s. The pane ID is printed anyway; go look at it. Raise the limit with `PRL_SPAWN_TIMEOUT` on a cold start.
- **A message is sitting unsent in the recipient's input box.** Its TUI was still starting when the text was typed: the terminal echoed the characters, but the program had not begun reading, so the Enter went nowhere. The scripts handle this by pressing Enter until the input box empties, and by letting a freshly spawned agent finish drawing before typing at it. If you hit it anyway, press Enter in the pane and raise `PRL_BOOTSTRAP_ATTEMPTS` (default 30) or `PRL_SEND_DELAY` (default 0.3s, the gap between the text and the Enter). If you are seeing this from something other than `notify.sh`, that is the bug — use `notify.sh`.
- **Something refuses to send because the input box "has text in it".** That text is almost certainly a placeholder suggestion, not a real message. Check `#{cursor_x}`, not the screen.
- **Characters arrive but do something strange.** A TUI in vim mode reads keystrokes as editing commands unless it is in insert mode. Check the pane's mode before blaming the transport.
- **Exit 14, or a member answering someone else's task.** The roster and the panes disagree. `roster.sh verify` shows which; `roster.sh sync` rebuilds the file from the panes. Do not send anything else until they agree.
- **A member went quiet for a round.** `roster.sh verify` distinguishes the cases that look identical from outside: `EXITED` (agent gone, pane at a shell), `GONE` (pane closed), `MISMATCH` (someone else is there now), `OK` (it is simply still working).
