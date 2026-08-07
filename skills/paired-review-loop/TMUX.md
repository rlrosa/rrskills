# tmux comms — instant wake-up and worker spawning

Optional. Everything here is an accelerator on top of the file protocol, never a replacement for it.
Without tmux the loop still works exactly as documented in [SKILL.md](SKILL.md); it just wakes on a polling watcher instead of a doorbell.

**The files stay the record.** The tmux channel carries a pointer — "your file changed, go read it" — and nothing else.
Task text, verdicts and evidence go in the session files, where they can be re-read, diffed and audited.
A nudge scrolls off a screen; a file does not.

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

- `spawn-member.sh` and `spawn-team.sh` fill both in as they start each agent.
- Started by hand? The thinker runs `scripts/session.sh register <dir> thinker`; each member runs `scripts/roster.sh add <dir> <name> <role> $TMUX_PANE $PWD '<agent>'`.
- Read one field with `scripts/roster.sh get <dir> worker pane`.

### The roster is a cache, not the truth

Every member's pane is also **tagged with its own identity** — `@prl_session`, `@prl_member`, `@prl_role`, `@prl_cmd` — as tmux pane options. Two consequences worth relying on:

- **A stale roster cannot misdeliver.** `roster.sh resolve` (which `notify.sh --member` uses) checks the pane's tag against the name you asked for and refuses if they disagree.
- **A lost roster is recoverable.** `scripts/roster.sh sync <dir>` rebuilds the whole file by scanning tagged panes across the tmux server, agent command and all. Deleting `roster.tsv` is survivable; the panes still know who they are.

`scripts/roster.sh verify <dir>` prints one line per member — `OK`, `GONE`, `EXITED`, `MISMATCH` — plus `UNLISTED` for tagged panes missing from the file. Run it whenever a notify fails or a member goes quiet.

## Ringing the doorbell

```
scripts/notify.sh --session <dir> --member <name> <message>   # preferred
scripts/notify.sh --session <dir> --role tester <message>     # every tester
scripts/notify.sh <pane-id> <message>                         # raw, unchecked
```

**Address by name, not by pane ID.** The named forms make the pane prove who it is first; a raw `%N` you cached earlier is how a task ends up in the wrong agent's terminal.

**Never hand-roll `tmux send-keys` yourself.** It looks like a one-liner and it is not. Two failure modes bite agents that try, and both look like success:

- **The Enter goes missing.** You type the text, the characters appear, and the message sits in the input box unsent — forever. A TUI that has not started reading input swallows the Enter, and a screen that shows your text is not proof it was submitted. `notify.sh` presses Enter until the input box actually empties.
- **A placeholder is mistaken for someone else's message.** Agent TUIs show greyed-out suggestions in an empty input box — codex offers `Write tests for @filename` — and an agent that reads the screen to check "is the box free?" sees text and refuses to send. Do not check the screen for that. **Check the cursor**: a placeholder leaves it parked at the start of the box, real characters push it along.

  Measured on an idle codex pane: placeholder showing, `#{cursor_x}` = 2. After typing 11 characters, 13. After `C-u`, back to 2 with the placeholder redrawn. The screen changed every time; only the cursor told the truth.

`notify.sh` uses the cursor for both checks and falls back to the screen only when a TUI does not move it.

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
| `0` | Delivered; the pane reacted | Nothing. End your turn and wait. |
| `10` | No tmux server reachable | Fall back to `scripts/watch.sh` on the counterpart's file. |
| `11` | No such pane | The counterpart is gone. Tell the human. |
| `12` | Pane is at a shell prompt | Its agent has exited. Nothing was sent. Tell the human; do not retry. |
| `13` | Keys sent, pane did not react | Treat as unreliable: arm a watcher as well, and say so. |
| `14` | The pane says it is someone else | Roster is stale. Nothing was sent. `roster.sh verify`, then fix it before sending to anyone. |
| `2` | Bad usage (multi-line message) | Fix the call. |

Two of these exist to stop a send rather than report one, and both fail *before* typing anything:

- **`12`** — a pane whose agent has exited is a live shell, and typing a message into a shell runs it as a command. `notify.sh` checks the pane's foreground command first.
- **`14`** — the pane's `@prl_member` tag does not match the member you addressed. Something reused or retagged that pane, so the roster is lying about where that agent is.

With `--role`, each member is reported separately and the exit code is the worst one seen, so one dead tester does not hide the others succeeding.

A delivered nudge proves the keystrokes landed, not that the recipient understood them. Only its reply on its own file proves that.

## Waiting

**With tmux, arm nothing.** Finish your turn and stop. The counterpart's nudge re-invokes you when there is something to read. There is no polling and no 60s floor on the round trip.

**Without tmux**, or after any non-zero exit above, fall back to the watcher, backgrounded, exactly one at a time. It takes several files and returns on the first to change, which is what a thinker waiting on a whole team needs:

```
scripts/watch.sh /tmp/prl-demo/members/*/out --interval 60 &
```

Waking is still not reading: whichever file fired, the thinker reads **every** member's `out`, because others may have reported while it was busy.

You can also run both — nudge *and* arm a long watcher (say 300s) — as a backstop against a nudge that was delivered but silently ignored. Kill the watcher when you wake.

## Spawning one member

```
scripts/spawn-member.sh --session /tmp/prl-demo --name worker --role worker \
  --cmd 'claude --model claude-sonnet-5' --cwd /path/to/repo
```

`--cmd` is passed through verbatim, so it carries whatever model and permission flags you want:
`'claude'`, `'codex'`, `'agy --dangerously-skip-permissions'`.

Add `--layout below` to stack the pane under the thinker instead of beside it, and `--size 30` to give it less of the split.

**Write `<session>/members/<name>/in` before spawning.** The bootstrap message then points the member straight at its first task and it starts without a further nudge. If the file is missing, the member is told to wait instead — an agent pointed at a file that does not exist will improvise, which is what the protocol exists to prevent.

## Spawning a whole team

```
scripts/spawn-team.sh --session /tmp/prl-demo --spec team.txt --cwd /path/to/repo
```

```
# name      role     agent
worker      worker   claude --model claude-sonnet-5
tester-1    tester   codex
tester-2    tester   agy --dangerously-skip-permissions
```

Everything after the role is the agent command, so it may contain flags and spaces. `-` as the spec reads it from stdin.

The first member gets a new window named `prl-<session>`; the rest are split into it and the window is re-tiled after each one, so nobody ends up in a sliver. Each spawn waits for its own agent to become interactive, so later members start up while earlier ones are still being bootstrapped — three stand-in members came up in under 10s.

Past **6 members** it warns: tiled panes stop being readable, and every member spends tokens every round. It is a warning, not a refusal — your terminal, your budget.

If a member fails to start, the ones already up are left running. `scripts/roster.sh verify` tells you where you got to.

What a spawn does, step by step:

1. Opens the pane, falling back to a new window automatically when the window is too small to divide.

   `--layout` is named after the resulting geometry, not tmux's `-h`/`-v`, which read backwards to most people:

   | `--layout` | Result | Aliases |
   | --- | --- | --- |
   | `right` | Side by side, on the right. Default. | `split`, `horizontal`, `h` |
   | `below` | Stacked, underneath. | `vertical`, `v` |
   | `window` | A new window of its own. | |

   `--size <n>` sets the new pane's share of the split as a percentage, 1–99 (default 50). A tall terminal suits `below`; a wide one suits `right`. `--into <pane-id>` splits a pane other than the thinker's, which is how `spawn-team.sh` gathers everyone into one window.
2. Records the member in `roster.tsv` and tags the pane with its identity — **before** launching the agent, so a member whose agent then fails to start still shows up in `roster.sh verify` instead of becoming an untracked pane.
3. Starts the pane on a plain shell and types the agent command into it, so the pane survives the agent exiting and you can still read the failure.
4. Waits for the agent to replace the shell as the pane's foreground command, then for the pane to stop redrawing. Both matter: an agent is the foreground command seconds before its TUI will accept a keystroke.
5. Sends one bootstrap line invoking this skill and naming the role, the name, the mailbox and both pane IDs, retrying until the pane confirms it took the message:

   ```
   /paired-review-loop You are the TESTER named 'tester-1'. Session dir: /tmp/prl-demo. Your inbox is /tmp/prl-demo/members/tester-1/in and you report in /tmp/prl-demo/members/tester-1/out. Your pane is %181 and the thinker's pane is %174. Read /tmp/prl-demo/members/tester-1/in and begin.
   ```

   The prefix follows the CLI: `/` for Claude and AGY, `$` for Codex, inferred from `--cmd` and overridable with `--skill-prefix`.
6. Prints the member's pane ID.

Every member's CLI must already have this skill installed — `./install.sh` from the repo root does that for Claude, AGY and Codex.

## When it does not work

- **Exit 10 from inside a pane you can see.** A sandboxed agent gets no route to the tmux socket even when it is running in tmux — Codex's workspace sandbox behaves this way. Re-run the notify outside the sandbox; the escalation is what the exit code is telling you to do.
- **Nudges land but nothing happens.** The counterpart is mid-turn; its harness queues the message. Wait a round before re-sending.
- **Exit 12 right after spawning.** The agent exited on startup. Look at the pane — it is still there on purpose — and check the command and its permission flags.
- **Spawn times out.** The agent never came up within 60s. The pane ID is printed anyway; go look at it. Raise the limit with `PRL_SPAWN_TIMEOUT` on a cold start.
- **A message is sitting unsent in the recipient's input box.** Its TUI was still starting when the text was typed: the terminal echoed the characters, but the program had not begun reading, so the Enter went nowhere. The scripts handle this by pressing Enter until the input box empties, and by letting a freshly spawned agent finish drawing before typing at it. If you hit it anyway, press Enter in the pane and raise `PRL_BOOTSTRAP_ATTEMPTS` (default 30) or `PRL_SEND_DELAY` (default 0.3s, the gap between the text and the Enter). If you are seeing this from something other than `notify.sh`, that is the bug — use `notify.sh`.
- **Something refuses to send because the input box "has text in it".** That text is almost certainly a placeholder suggestion, not a real message. Check `#{cursor_x}`, not the screen.
- **Characters arrive but do something strange.** A TUI in vim mode reads keystrokes as editing commands unless it is in insert mode. Check the pane's mode before blaming the transport.
- **Exit 14, or a member answering someone else's task.** The roster and the panes disagree. `roster.sh verify` shows which; `roster.sh sync` rebuilds the file from the panes. Do not send anything else until they agree.
- **A member went quiet for a round.** `roster.sh verify` distinguishes the cases that look identical from outside: `EXITED` (agent gone, pane at a shell), `GONE` (pane closed), `MISMATCH` (someone else is there now), `OK` (it is simply still working).
