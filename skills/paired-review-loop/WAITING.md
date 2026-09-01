# Waiting — how to arm a watcher so it actually wakes you

Read the row for **your** agent. Getting this wrong is the single most common way a session stalls, and it fails silently: you believe you are waiting, and nothing is ever going to wake you.

## Run it in the foreground, as your last action

```
scripts/watch.sh '<dir>/members/*/out' --interval 15 --timeout 1800
```

Call it in the **foreground**, as the last thing you do in the turn. The call blocks until a file changes or the deadline passes, and then **control comes back to you** — which is the only thing that counts.

That last point is the whole idea, and it is easy to get backwards:

> In an agent harness, a fallback means *control returns to you*. It does not mean *a process notices something*.

A process that notices a stall and cannot give you a turn has achieved nothing. One session built exactly that: a detached monitor spotted a stall, printed a perfect diagnosis, and wrote it to a log nobody was reading.

## What does not work

| Way of arming it | What happens |
| --- | --- |
| **Foreground, blocking** | Works. One call, one wake. Field-tested across a long session without a single failure. |
| **Harness background task** (Claude Code `run_in_background: true`, codex background terminal) | **Can be reaped**, and on some harnesses **wakes you repeatedly**. See below — this is the expensive one. |
| **Trailing `&`** | Never works. The shell backgrounds it, your call returns in milliseconds, and nothing is watching the watcher. |
| **`nohup` / `setsid`** | Survives and is useless. A process outside the harness cannot give an agent a turn. |

## Two knobs, and they are not interchangeable

| | What it decides | What it costs |
| --- | --- | --- |
| `--interval` | How fast a **real reply** wakes you | A few `stat` calls. No model time. Free. |
| `--timeout` | How often you are woken when **nothing has happened** | A paid turn, every time |

**Shortening the timeout does not make the loop more responsive.** This is the mistake that burns the most money, and it feels like diligence.

Measured:

| Settings | Real reply arrives in | Idle wakeups per hour |
| --- | --- | --- |
| `--interval 30 --timeout 60` | 30s | **60** |
| `--interval 15 --timeout 1800` | 15s | **6** |

The "responsive" one is twice as slow and ten times more expensive. If you want to react faster, **lower `--interval`** — it is free. The deadline exists only for the case where nobody ever replies, so it should be long.

`watch.sh` warns below 120s.

## The interval is free. Wakeups are not.

These get confused, and confusing them is expensive.

`--interval` is how often **the script** stats the files. Measured: 34 `stat()` calls over three seconds. No model, no tokens, no turn. You could set it to 1 and it would still be free.

What costs is **being handed a turn**. One `watch.sh` call is one wake: it blocks, stays completely silent for the whole wait — 0 bytes written across four seconds of waiting — then prints one line and exits.

So backgrounding it is not a small stylistic difference. A harness that gives you a turn each time it checks on a background command turns one cheap wait into a stream of paid wakeups. That has been seen live: a thinker woken over and over to report "no handoff yet", "still active", "no report yet", while the script sat there silently doing exactly what it was asked.

**Never report progress on a wait.** If you wake with nothing to act on, do not narrate it — re-arm and stop. A turn that says "still waiting" has cost money to tell somebody something they could have assumed.

## Codex specifically

**Do not put `watch.sh` in a background terminal.** Codex hands you a turn every time it looks at one, which is the failure above. Call it in the foreground as your last action.

If codex's foreground cap is shorter than your `--timeout`, lower the timeout to sit under the cap rather than reaching for the background — a shorter wait that ends cleanly beats a long one that wakes you ten times.

### The `/goal` lifecycle, from the thinker's side

A codex member driven by a persistent `/goal` has three states, and the third is the one that strands sessions:

| Footer says | What it means | What to do |
| --- | --- | --- |
| `Working` | Executing its task | Nothing. Leave it. |
| `Ready` | Idle between turns | A nudge will be picked up. |
| `Goal stalled (/goal resume)` | It ran out of authorised work and **parked**. It will not look at its inbox again on its own. | Write the next `in`, then `roster.sh kick` — a plain nudge is not enough. |

That third state is reached honestly: the member finished its task, found no new instruction across a few continuations, and stopped rather than invent work. It is doing what it was told. But it is now deaf to the mailbox until resumed, so writing a new `in` alone changes nothing.

`roster.sh kick` reads that footer and sends `/goal resume` instead of a nudge when it sees it — and then confirms the pane is really working, because a `/goal resume` whose Enter is swallowed sits in the input box while the footer still reads `Goal stalled`. That happened twice in one session.

**A persistent `/goal` will resume you the moment you stop.** That is what it is for, and it is why ending a turn without a blocking call is so expensive here: `/goal` immediately gives you another turn, you find nothing new in your inbox, you say "no change", and it resumes you again. One worker spent twenty-odd turns that way.

The blocking wait is what absorbs it. While `watch.sh` is running in the foreground, `/goal` has nothing to resume — you are already busy. So the rule is not just "arm a watcher", it is **arm it as the last thing you do, in the foreground, and let it block.**

And if `/goal` resumes you while your task is unfinished, that is not a prompt for a status report. Carry on implementing.

## Wait long. Half an hour is the default for a reason

Every deadline that expires is a paid turn, and it tells you nothing you did not already know. Waiting longer costs nothing; waking costs every time.

| `--timeout` | Wakes per hour | Across an 8-hour night |
| --- | --- | --- |
| 60s | 60 | 480 |
| 540s | 6.7 | 53 |
| **1800s (default)** | **2** | **16** |

Nothing is lost by the long wait: a real reply still arrives within one `--interval`. The deadline only bounds the case where nobody replies at all, and that case does not get better by being checked more often.

### The one thing that limits it

A **foreground** call is capped by your harness — 600s in Claude Code. A 1800s foreground wait gets severed by the tool at 600s, and a severed call is indistinguishable from a real timeout.

So pick per harness:

- **Foreground under a cap:** use `--timeout 540` (just under 600s), and accept ~53 wakes overnight. Set `PRL_TOOL_TIMEOUT_CEILING=600` and `watch.sh` will warn you when you exceed it.
- **Background, harness-tracked:** no cap applies, so the 1800s default stands and you get 16. This is the cheaper option where your harness reliably notifies you on exit — but see the reaping and repeated-wake caveats above, and never in a codex background terminal.

If neither is reliable for you, prefer the shorter foreground wait: an ambiguous outcome costs more to untangle than the extra wakes cost to serve.

## Why a trailing `&` does not work

```
scripts/watch.sh <file> --timeout 1800 &      # WRONG
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
