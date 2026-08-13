# Waiting — how to arm a watcher so it actually wakes you

Read the row for **your** agent. Getting this wrong is the single most common way a session stalls, and it fails silently: you believe you are waiting, and nothing is ever going to wake you.

## What "waiting" actually requires

`scripts/watch.sh` does not wake you. It exits — and your **harness** wakes you because it was watching that process. So the requirement is not "start the watcher in the background". It is:

> Start the watcher in a way your harness tracks, so that when it exits, your harness gives you a turn.

Those are different things, and the difference is the whole bug.

## Per agent

| Agent | How to arm it |
| --- | --- |
| **Claude Code** | The Bash tool's **`run_in_background: true`** parameter. Not a trailing `&`. |
| **Codex, AGY, anything else** | Use your harness's equivalent — whatever gives you a turn when a tracked command finishes. If it has none, see *If you cannot be woken* below. |

## Why a trailing `&` does not work

```
scripts/watch.sh <file> --timeout 900 &      # WRONG
```

The shell backgrounds the process and your foreground call returns immediately. Your harness saw a command that finished in milliseconds, so there is nothing left for it to watch, and **nothing will ever hand you a turn**.

Worse, this usually *looks* like it worked. Measured on this machine, a child started with `&` inside a foreground call kept running happily after that call returned, and one real watcher was found still polling long after the agent that started it had been killed. So do not expect the process to die and give the game away. **A live watcher is not a wake-up.** It only counts if your harness is watching *it*.

The same trap catches `nohup … &` and wrapping the `&` inside another backgrounded call: the wrapper exits instantly on the `&`, your harness reports "completed, exit 0" straight away, and you conclude the watcher is armed when it is merely orphaned.

**How to tell which happened.** If arming your watcher returned in well under a second, it is not armed. A correctly armed watcher does not report back until it fires, seconds to minutes later.

## If you cannot be woken

Do not fake it. An agent that ends its turn with nothing armed is not waiting, it is stopping.

Instead:

1. Write your `out` as usual.
2. Say in it, plainly, that your harness cannot re-invoke you and you are stopped rather than waiting.
3. Stop.

The thinker polls the team and pokes members that have gone quiet — that is what `notify.sh` is for. Being honest that you cannot self-wake gets you poked promptly. Pretending to wait gets you forgotten.

## On any wake

1. **Kill your watcher** before doing anything else, so an old one cannot fire later and cause a spurious round: `pkill -f 'watch[.]sh /tmp/prl-'` — the `[.]` stops the pattern matching the pkill itself.
2. Read the file, do the work, write your file.
3. Arm the next watcher, the tracked way.

Exactly one watcher at a time, always.
