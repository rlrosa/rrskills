#!/usr/bin/env bash
# watch.sh <file> [file...] [--interval <seconds>] [--timeout <seconds>]
#
# Waits for one of the files to change (its mtime increases, or it first
# appears), or for the deadline to pass.
#
# ONE CALL WAKES YOU ONCE. It blocks, prints a single line, and exits. It is
# silent for the whole wait, so there is nothing to check on and no reason to
# look at it while it runs.
#
# The two knobs do different jobs, and confusing them is expensive:
#
#   --interval  how fast a real reply wakes you. Costs a handful of stat calls
#               and no model time at all, so 15s is cheap and 1s would be too.
#   --timeout   how often you are woken when NOTHING has happened. Every one of
#               those is a paid turn.
#
# A short timeout does NOT make the loop more responsive - the interval decides
# that. Measured: --interval 30 --timeout 60 answers a real reply in 30s and
# wakes you 60 times an hour while idle; --interval 15 --timeout 540 answers in
# 15s and wakes you 6 times. Shortening the timeout to "avoid stalling" buys
# nothing and pays ten times over.
#
# RUN IT IN THE FOREGROUND, as the last thing you do in a turn. The call blocks
# until a file changes or the deadline passes, and then control returns to you.
# That is the only arrangement that reliably works:
#
#   - Backgrounded through a harness's background-task facility it can be
#     reaped (six consecutive arms killed inside a minute, after four earlier
#     ones survived their full deadline) - and worse, some harnesses hand you a
#     turn every time they check on it. One thinker was woken over and over to
#     say "still nothing" while this script sat there silently doing its job.
#     Backgrounding converts one cheap wait into a stream of paid wakeups.
#   - Detached with `nohup` or `setsid` it survives and is useless, because a
#     process outside the harness cannot give an agent a turn. One such monitor
#     detected a stall perfectly and wrote its diagnosis to a log nobody read.
#
# In an agent harness a fallback means *control comes back to you*, not *a
# process notices something*. A foreground call is what does that. See
# WAITING.md.
#
#   scripts/watch.sh '/tmp/prl-demo/members/*/out' --timeout 540
#
# Pass --session <dir> and a TIMEOUT also prints who owes what, so a wake with
# nothing on it still arrives with the answer instead of costing you a second
# call to work it out.
#
# Both outcomes exit 0 and are told apart by the first word of stdout. Neither
# is an error, so nothing announces a failure that did not happen:
#
#   CHANGED <file> <mtime>   somebody wrote something; go read it.
#   TIMEOUT <seconds>        nothing happened. Do NOT assume you are still
#                            waiting: run status.sh and find out whose move it
#                            actually is.
#
# Only a usage mistake exits non-zero (2).
#
# The deadline is the point. A doorbell that is never rung, or is rung and
# ignored, leaves both sides believing the other owes a reply, and a watcher
# that only ever returns on a change cannot break that — nothing changed, so
# nothing fires. Waiting with a deadline is what makes such a stall temporary.
# That is why there is a default deadline at all rather than "forever";
# --timeout 0 restores unbounded waiting for anyone who explicitly wants it.
#
# With several files it returns on the first one to change. That is what the
# thinker needs when it has a team: any member reporting should wake it. Note
# that waking is not the same as reading — on every wake the thinker reads
# every member's out file, because others may have reported while it was busy.
#
# Watching the containing directory instead would not work: a directory's mtime
# changes when files are created or removed, not when a file's contents are
# overwritten, and these mailboxes are overwritten every round.
#
# Files are the channel; this is how both sides wait on them. notify.sh is the
# thinker's separate tool for poking a member that has gone quiet - see TMUX.md.
#
# Rules:
#   - Keep exactly ONE mailbox watcher at a time.
#   - Default poll interval is 15s; pass --interval to change it.
#   - To replace an old watcher without the pkill matching ITSELF, use a regex
#     with [.] for the literal dot:   pkill -f 'watch[.]sh /tmp/prl-'
set -u

# Files are the channel now, not a fallback, so polling is how a round trip
# actually completes. A few stat calls cost nothing; waiting a minute to notice
# a report that is already on disk costs a round.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SESSION=""
INTERVAL=15
# Deliberately under the 600s ceiling harnesses tend to put on a foreground
# command. A deadline past that cap means the tool severs the call before the
# script finishes, and the agent cannot tell "nothing happened" from "my harness
# cut me off". A default that produces ambiguous outcomes is worse than none.
TIMEOUT=540
PRL_TOOL_TIMEOUT_CEILING="${PRL_TOOL_TIMEOUT_CEILING:-600}"
# Below this a deadline is being used as a poll, which is what it is not for.
PRL_SHORT_TIMEOUT="${PRL_SHORT_TIMEOUT:-120}"
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    -h | --help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0
      ;;
    *) FILES+=("$1"); shift ;;
  esac
done

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "usage: watch.sh <file> [file...] [--interval <seconds>] [--timeout <seconds>]" >&2
  exit 2
fi

for number in "$INTERVAL" "$TIMEOUT"; do
  case "$number" in
    '' | *[!0-9]*)
      echo "watch: --interval and --timeout take whole seconds (got '$number')" >&2
      exit 2
      ;;
  esac
done

# A second positional that is all digits is the old `watch.sh <file> <interval>`
# form, kept working so existing habits and docs do not silently start watching
# a file named "30".
if [ "${#FILES[@]}" -eq 2 ]; then
  case "${FILES[1]}" in
    '' | *[!0-9]*) ;;
    *)
      INTERVAL="${FILES[1]}"
      FILES=("${FILES[0]}")
      ;;
  esac
fi

# Any other bare number is a mistake, not a filename. The usage line reads
# `watch.sh <file> [file...] [--interval <n>]`, which makes `watch.sh <file> 60`
# the natural thing to type — and left alone it waits patiently for a file
# literally called "60" to appear, with no error and no output, until the
# deadline. Reported twice from one session as the costliest small trap here.
for candidate in "${FILES[@]}"; do
  case "$candidate" in
    '' | *[!0-9]*) ;;
    *)
      echo "watch: '$candidate' is a number, not a file. Did you mean --interval $candidate?" >&2
      exit 2
      ;;
  esac
done

mtime_of() {
  stat -c %Y "$1" 2>/dev/null || echo 0
}

# Expand the arguments afresh on every poll, rather than trusting the shell to
# have done it once at launch.
#
# `watch.sh <dir>/members/*/out` is the idiom a thinker waiting on its team
# needs, and unquoted it breaks in the exact case that matters: on round one no
# out file exists, so the shell finds nothing to expand and hands over the
# pattern verbatim as a filename that can never exist. The watcher then sits
# there while the worker reports, and only the deadline eventually frees it.
# Expanding here also means a member who joins mid-wait is picked up, which a
# one-shot expansion could never do.
expand_targets() {
  local pattern
  shopt -s nullglob
  for pattern in "${FILES[@]}"; do
    case "$pattern" in
      # Globs may legitimately match nothing yet; nullglob drops them until
      # they do.
      *[*?[]*) printf '%s\n' $pattern ;;
      # A plain path is kept whether or not it exists, so its first appearance
      # still counts as a change.
      *) printf '%s\n' "$pattern" ;;
    esac
  done
  shopt -u nullglob
}

declare -A baseline=()
while read -r target; do
  [ -z "$target" ] && continue
  baseline[$target]=$(mtime_of "$target")
done < <(expand_targets)

# A deadline past the harness's own cap on a foreground command means the tool
# ends the call, not this script — and the caller then cannot tell "nothing
# happened" from "I was cut off".
# A very short deadline is nearly always a misunderstanding of what it is for.
if [ "$TIMEOUT" -ne 0 ] && [ "$TIMEOUT" -lt "$PRL_SHORT_TIMEOUT" ]; then
  echo "watch: --timeout ${TIMEOUT}s wakes you $((3600 / TIMEOUT)) times an hour while nothing" >&2
  echo "watch: happens, and does not make a real reply arrive any sooner - --interval ${INTERVAL}s" >&2
  echo "watch: decides that, and costs nothing. If you want to react faster, lower --interval." >&2
  echo "watch: The deadline is a safety net for the case where nobody replies at all." >&2
fi

if [ "$TIMEOUT" -gt "$PRL_TOOL_TIMEOUT_CEILING" ]; then
  echo "watch: --timeout ${TIMEOUT}s is above the ${PRL_TOOL_TIMEOUT_CEILING}s a foreground" >&2
  echo "watch: call usually gets. Your harness may cut this off first, and you will not be" >&2
  echo "watch: able to tell that from a real timeout. Use --timeout $((PRL_TOOL_TIMEOUT_CEILING - 60))." >&2
fi

deadline=$((SECONDS + TIMEOUT))

while true; do
  while read -r target; do
    [ -z "$target" ] && continue
    current=$(mtime_of "$target")
    # A path that was not there when we armed is itself the news.
    if [ -z "${baseline[$target]+set}" ] || [ "$current" -gt "${baseline[$target]}" ]; then
      echo "CHANGED $target $current"
      exit 0
    fi
  done < <(expand_targets)
  # Check the files once more before giving up, so a write landing during the
  # final sleep is reported as a change rather than as a timeout.
  if [ "$TIMEOUT" -ne 0 ] && [ "$SECONDS" -ge "$deadline" ]; then
    # Exit 0, not an error code. Reaching the deadline is a normal way for a
    # wait to end, and a non-zero exit made every harness announce "Background
    # command failed with exit code 3" — sending the reader off to check
    # whether something had broken, every single time. Branch on the word.
    echo "TIMEOUT $TIMEOUT"
    # Spend the wake usefully. Nothing arriving is exactly when you need to know
    # whose move it is, and working that out should not cost another round.
    [ -n "$SESSION" ] && "$SCRIPT_DIR/status.sh" "$SESSION" 2>&1
    exit 0
  fi
  sleep "$INTERVAL"
done
