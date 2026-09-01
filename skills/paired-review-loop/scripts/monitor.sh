#!/usr/bin/env bash
# monitor.sh <session-dir> [--interval <seconds>] [--stall-after <seconds>]
#
# Emits ONE LINE whenever a member changes state, and says nothing at all in
# between. Built to be run under a harness's persistent monitor facility — in
# Claude Code, the Monitor tool with persistent: true.
#
# Why this exists rather than another watch.sh:
#
#   - A persistent monitor is not reaped. Plain background commands are, over
#     and over: "Background command was stopped", repeatedly, mid-wait.
#   - It stays armed across rounds. watch.sh has to be re-armed after every
#     wake, and forgetting is the single most common way a loop dies.
#   - It costs a turn per *transition*, not per deadline. A wait that expires
#     with nothing to say never reaches you at all.
#
# Each line is an event your harness turns into one notification:
#
#   UNSTARTED worker  registered but never given a task
#   REPORTED worker   wrote its out; you owe the next task
#   WORKING  worker   picked up the task you wrote
#   STALLED  worker   has owed a reply for a while and its pane is idle
#   EXITED   worker   its agent quit; the pane is back at a shell
#   GONE     worker   its pane was closed
#   MISMATCH worker   its pane now belongs to somebody else
#
# Keep the emitted volume low or your harness will stop the monitor for noise.
# That is why nothing is printed while a state holds, however long it holds.
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

SESSION=""
INTERVAL=30

while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --stall-after) PRL_STALL_AFTER="$2"; export PRL_STALL_AFTER; shift 2 ;;
    -h | --help) usage 0 ;;
    --*) echo "monitor: unknown option '$1'" >&2; usage 2 ;;
    *) SESSION="$1"; shift ;;
  esac
done

[ -n "$SESSION" ] || usage 2
[ -d "$SESSION" ] || { echo "monitor: no such session dir: $SESSION" >&2; exit 1; }
SESSION=$(cd "$SESSION" && pwd)
prl_assert_session_owner "$SESSION" || exit 4

# Read the team's state from status.sh rather than deriving it again here, so
# the two can never disagree about who owes what.
declare -A last_state=() candidate=() candidate_seen=()

# How many consecutive polls a flickery state must survive before it is
# announced.
#
# Some panes flicker: a foreground command that spawns short-lived children
# reads as a different process from one poll to the next, and reporting each
# flip would bury the real transitions and get the monitor stopped for noise.
#
# This applies only to states read off the pane. REPORTED and UNSTARTED come
# from mailbox timestamps, which cannot flicker, and they are the ones the
# thinker is actually waiting for - so they go out on the first poll rather
# than paying a confirmation delay on every round.
PRL_MONITOR_CONFIRM="${PRL_MONITOR_CONFIRM:-2}"

# True for states derived from the pane rather than from the mailbox.
needs_confirming() {
  case "$1" in
    REPORTED | UNSTARTED) return 1 ;;
    *) return 0 ;;
  esac
}

while true; do
  while read -r name owes _since pane note; do
    [ -z "$name" ] && continue

    # Fold the stall judgement into the state so a member that goes quiet is a
    # transition, not a silent continuation of "owes a reply".
    case "$note" in
      # Before the first task exists, "the thinker owes" is true but has
      # nothing to do with a report having been written.
      *"no task written yet"*) situation="UNSTARTED" ;;
      *"pane is idle"*) situation="STALLED" ;;
      *)
        case "$pane" in
          OK) [ "$owes" = "thinker" ] && situation="REPORTED" || situation="WORKING" ;;
          *) situation="$pane" ;;
        esac
        ;;
    esac

    if [ "${last_state[$name]:-}" = "$situation" ]; then
      candidate[$name]=""
      continue
    fi

    if needs_confirming "$situation"; then
      if [ "${candidate[$name]:-}" = "$situation" ]; then
        candidate_seen[$name]=$(( ${candidate_seen[$name]:-0} + 1 ))
      else
        candidate[$name]="$situation"
        candidate_seen[$name]=1
      fi
      [ "${candidate_seen[$name]}" -ge "$PRL_MONITOR_CONFIRM" ] || continue
    fi

    last_state[$name]="$situation"
    candidate[$name]=""
      case "$situation" in
        UNSTARTED) printf 'UNSTARTED %s - registered, no task written yet; you owe the first one\n' "$name" ;;
        REPORTED) printf 'REPORTED %s - wrote its out; you owe the next task\n' "$name" ;;
        WORKING) printf 'WORKING %s - has the task and is working\n' "$name" ;;
        STALLED) printf 'STALLED %s - %s\n' "$name" "$note" ;;
        *) printf '%s %s - %s\n' "$situation" "$name" "$note" ;;
    esac
    # Skip the two header lines status.sh prints before the table.
  done < <("$SCRIPT_DIR/status.sh" "$SESSION" 2>/dev/null | tail -n +3)

  sleep "$INTERVAL"
done
