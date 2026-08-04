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

Pane IDs live in `<session>/session.env`, which both sides read:

```
PRL_SESSION_DIR='/tmp/prl-demo'
PRL_THINKER_PANE='%174'
PRL_WORKER_PANE='%180'
PRL_WORKER_CMD='claude --model claude-sonnet-5'
PRL_WORKER_CWD='/home/rrosa/repo'
```

- `scripts/spawn-worker.sh` writes every key when the thinker starts the worker itself.
- When the two agents were started by hand, each registers itself once: `scripts/session.sh register <session-dir> thinker` (or `worker`).
- Read one value with `scripts/session.sh get <session-dir> PRL_WORKER_PANE`, or source the file.

## Ringing the doorbell

```
scripts/notify.sh <pane-id> <message>
```

Write your file first, then notify — otherwise the counterpart wakes up and reads the previous round.

Keep the message to one line that names the file to read:

```
prl: thinker.out updated - read /tmp/prl-demo/thinker.out
prl: worker.out updated - round 3 report + evidence/04-*.txt
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
| `2` | Bad usage (multi-line message) | Fix the call. |

Exit `12` is the one worth understanding. A pane whose agent has exited is a live shell, and typing a message into a shell runs it as a command. `notify.sh` checks the pane's foreground command and refuses to send in that case, so a dead worker fails loudly instead of executing your prose.

A delivered nudge proves the keystrokes landed, not that the counterpart understood them. Only its reply on its own file proves that.

## Waiting

**With tmux, arm nothing.** Finish your turn and stop. The counterpart's nudge re-invokes you when there is something to read. There is no polling and no 60s floor on the round trip.

**Without tmux**, or after any non-zero exit above, fall back to the watcher: `scripts/watch.sh <counterpart-file> [interval_s=60]`, backgrounded, exactly one at a time.

You can also run both — nudge the counterpart *and* arm a long watcher (say 300s) — if you want a backstop against a nudge that was delivered but silently ignored. Kill the watcher when you wake.

## Spawning a worker

The thinker can open the worker's pane and start the agent in it:

```
scripts/spawn-worker.sh --session /tmp/prl-demo --cmd 'claude --model claude-sonnet-5' --cwd /path/to/repo
```

`--cmd` is passed through verbatim, so it carries whatever model and permission flags you want:
`'claude'`, `'codex'`, `'agy --dangerously-skip-permissions'`.

Add `--layout below` to stack the worker under the thinker instead of beside it, and `--size 30` to give it less of the split:

```
scripts/spawn-worker.sh --session /tmp/prl-demo --cmd 'codex' --layout below --size 30
```

**Write `<session>/thinker.out` before spawning.** The bootstrap message then points the worker straight at its first task and the loop starts without a further nudge. If the file is missing, the worker is told to wait instead — a worker pointed at a file that does not exist will improvise, which is what the protocol exists to prevent.

What it does:

1. Splits the thinker's own window, falling back to a new window automatically when the window is too small to divide.

   `--layout` is named after the resulting geometry, not tmux's `-h`/`-v`, which read backwards to most people:

   | `--layout` | Result | Aliases |
   | --- | --- | --- |
   | `right` | Side by side, worker on the right. Default. | `split`, `horizontal`, `h` |
   | `below` | Stacked, worker underneath. | `vertical`, `v` |
   | `window` | A new window of its own. | |

   `--size <n>` sets the worker pane's share of the split as a percentage, 1–99 (default 50). A tall terminal suits `below`; a wide one suits `right`.
2. Starts the pane on a plain shell and types the agent command into it, so the pane survives the agent exiting and you can still read the failure.
3. Waits for the agent to replace the shell as the pane's foreground command, then for the pane to stop redrawing. Both matter: an agent is the foreground command seconds before its TUI will accept a keystroke.
4. Sends one bootstrap line invoking this skill and naming the role, the session dir and both pane IDs, retrying until the pane confirms it took the message:

   ```
   /paired-review-loop You are the WORKER. Session dir: /tmp/prl-demo. Your pane is %180 and the thinker's pane is %174. Read /tmp/prl-demo/thinker.out and begin.
   ```

   The prefix follows the CLI: `/` for Claude and AGY, `$` for Codex, inferred from `--cmd` and overridable with `--skill-prefix`.
5. Writes `session.env` and prints the worker's pane ID.

The worker's CLI must already have this skill installed — `./install.sh` from the repo root does that for Claude, AGY and Codex.

## When it does not work

- **Exit 10 from inside a pane you can see.** A sandboxed agent gets no route to the tmux socket even when it is running in tmux — Codex's workspace sandbox behaves this way. Re-run the notify outside the sandbox; the escalation is what the exit code is telling you to do.
- **Nudges land but nothing happens.** The counterpart is mid-turn; its harness queues the message. Wait a round before re-sending.
- **Exit 12 right after spawning.** The agent exited on startup. Look at the pane — it is still there on purpose — and check the command and its permission flags.
- **Spawn times out.** The agent never came up within 60s. The pane ID is printed anyway; go look at it. Raise the limit with `PRL_SPAWN_TIMEOUT` on a cold start.
- **A message is sitting unsent in the counterpart's input box.** Its TUI was still starting when the text was typed: the terminal echoed the characters, but the program had not begun reading, so the Enter went nowhere. The scripts handle this by pressing Enter until the pane reacts, and by letting a freshly spawned agent finish drawing before typing at it. If you hit it anyway, press Enter in the pane and raise `PRL_BOOTSTRAP_ATTEMPTS` (default 30) or `PRL_SEND_DELAY` (default 0.3s, the gap between the text and the Enter).
- **Characters arrive but do something strange.** A TUI in vim mode reads keystrokes as editing commands unless it is in insert mode. Check the pane's mode before blaming the transport.
