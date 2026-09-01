# Waiting — how to arm a watcher so it actually wakes you

Read the row for **your** agent. Getting this wrong is the single most common way a session stalls, and it fails silently: you believe you are waiting, and nothing is ever going to wake you.

## Pick foreground or background by what your harness does to each

This is the decision that costs real money, and it is not a style preference. One session spent **about $15 in a single night purely on waiting** — eight foreground waits, each expiring, each billing a full context re-read to learn nothing.

The trap is structural rather than a bad parameter: **a foreground deadline longer than your harness's cap on a foreground command is always wrong.** It cannot possibly run to completion, so it is guaranteed to be severed and bill a turn, every single time, no matter what number you wrote.

At the measured ~$1.88 a wake:

| How it is armed | Wakes per idle hour | Cost per idle hour |
| --- | --- | --- |
| Foreground, `--timeout 540` (under a 600s cap) | 6.7 | ~$12.50 |
| Foreground, `--timeout 1800` (severed at 600s anyway) | 6.0 | ~$11.25 |
| **Background, `--timeout 1800`** | **2.0** | **~$3.75** |
| Background, `--timeout 3600` | 1.0 | ~$1.88 |

Note what that table says: in the foreground the deadline barely matters, because the cap decides. Choosing background is worth more than any timeout you can pick.

### So, per harness

| Harness | Arm it | Deadline |
| --- | --- | --- |
| **Claude Code** | Bash tool **`run_in_background: true`** | 1800s or more. One re-invoke when it exits, whichever way it ends. |
| **Codex** | **Foreground**, as your last action | Under its foreground cap. Never put it in a background terminal — codex gives you a turn every time it checks on one, which is the expensive failure in the other direction. |
| **Anything else** | Foreground, last action | Under whatever cap it has. Find the cap first. |

### The tell that you got this wrong

If your wait ended with **your tool reporting a timeout** rather than the script printing a `TIMEOUT <seconds>` line, the script never finished — your harness severed it. You are paying for a wait that could never have completed. Shorten the deadline below the cap, or background it.

`watch.sh` will warn you in advance if you tell it the cap: `PRL_TOOL_TIMEOUT_CEILING=600`.

### On backgrounding being unreliable

It has been reported reaped — one session saw six consecutive arms killed inside a minute after four had survived their full deadline — and that is a real risk: a reaped watcher never wakes you at all. Set against a certain ~$12 an hour for the foreground alternative, take the risk and let the stall be caught by a human prompt and `status.sh`, which diagnoses it in one command.

What is never acceptable is `&` or `nohup`. Those neither wake you nor get tracked; the process survives and is useless, because something outside the harness cannot give an agent a turn.

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

## Wait long — but only backgrounding makes that mean anything

Every deadline that expires is a paid turn, and it tells you nothing you did not already know. Waiting longer costs nothing; waking costs every time. A real reply still arrives within one `--interval` regardless, so the deadline only bounds the case where nobody replies at all.

| `--timeout` | Wakes per hour | Across an 8-hour night |
| --- | --- | --- |
| 60s | 60 | 480 |
| 540s | 6.7 | 53 |
| **1800s (default)** | **2** | **16** |

**Those numbers only hold if the wait can actually run that long.** In the foreground under a 600s cap, 1800s and 540s both cost about six wakes an hour, because the cap decides and the deadline is ignored. The saving is real only for a watcher your harness tracks in the background.

So: background it and keep the 1800s default, or foreground it under the cap and accept the wakes. Writing a long deadline into a foreground call buys nothing at all.

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
