# Waiting — how to arm a watcher so it actually wakes you

Read the row for **your** agent. Getting this wrong is the single most common way a session stalls, and it fails silently: you believe you are waiting, and nothing is ever going to wake you.

## Run it in the foreground, as your last action

```
scripts/watch.sh '<dir>/members/*/out' --interval 15 --timeout 540
```

Call it in the **foreground**, as the last thing you do in the turn. The call blocks until a file changes or the deadline passes, and then **control comes back to you** — which is the only thing that counts.

That last point is the whole idea, and it is easy to get backwards:

> In an agent harness, a fallback means *control returns to you*. It does not mean *a process notices something*.

A process that notices a stall and cannot give you a turn has achieved nothing. One session built exactly that: a detached monitor spotted a stall, printed a perfect diagnosis, and wrote it to a log nobody was reading.

## What does not work

| Way of arming it | What happens |
| --- | --- |
| **Foreground, blocking** | Works. Field-tested across a long session without a single failure. |
| **Harness background task** (Claude Code `run_in_background: true`) | **Can be reaped.** One session saw six consecutive arms killed inside a minute, after four earlier ones had survived their full deadline. Use it only where you can tolerate losing the wake. |
| **Trailing `&`** | Never works. The shell backgrounds it, your call returns in milliseconds, and nothing is watching the watcher. |
| **`nohup` / `setsid`** | Survives and is useless. A process outside the harness cannot give an agent a turn. |

## Keep the deadline under your harness's cap

Harnesses cap a foreground call — 600s in Claude Code. A `--timeout` above that means **the tool ends your call, not the script**, and you cannot tell "nothing happened" from "I was cut off".

So the default is **540s**, safely under. `watch.sh` warns if you ask for more. If your harness has a different cap, stay about a minute below it.

## Why a trailing `&` does not work

```
scripts/watch.sh <file> --timeout 540 &      # WRONG
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

## "Exactly one watcher" means one on the mailboxes

It is a rule about **mailbox watchers**, not about all background work. Tailing a build log, monitoring a long job, waiting on a deploy — those are separate concerns and you may have them running at the same time as your one mailbox watcher.

Two things follow:

- **`nohup` any long job you start**, and do not rely on the watcher's lifetime to keep it alive. Harnesses reap background commands: one was stopped with *"Background command … was stopped"*, and only `nohup` saved the batch it had launched.
- **Keep the mailbox watcher single** so waking is unambiguous. Two of those and you cannot tell which round a wake belongs to.
