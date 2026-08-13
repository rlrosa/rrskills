#!/usr/bin/env bash
# watch.sh <file> [file...] [--interval <seconds>] [--timeout <seconds>]
#
# Waits for one of the files to change (its mtime increases, or it first
# appears), or for the deadline to pass. Run it backgrounded so your harness
# re-invokes you when it exits:
#   scripts/watch.sh /tmp/prl-demo/members/*/out &
#
#   exit 0   CHANGED <file> <mtime>  - somebody wrote something; go read it.
#   exit 3   TIMEOUT <seconds>       - nothing happened. Do NOT assume you are
#                                      still waiting: run status.sh and find out
#                                      whose move it actually is.
#
# The deadline is the point. A doorbell that is never rung, or is rung and
# ignored, leaves both sides believing the other owes a reply, and a watcher
# that only ever returns on a change cannot break that — nothing changed, so
# nothing fires. Waiting with a deadline is what makes such a stall temporary.
# That is why the default is 900s rather than "forever"; --timeout 0 restores
# the old unbounded behaviour for anyone who explicitly wants it.
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
# Under tmux notify.sh wakes the recipient at once, so this runs alongside it as
# the backstop rather than the primary signal - see TMUX.md.
#
# Rules:
#   - Keep exactly ONE watcher armed at a time, and kill it when you wake.
#   - Default poll interval is 60s; pass --interval to change it.
#   - To replace an old watcher without the pkill matching ITSELF, use a regex
#     with [.] for the literal dot:   pkill -f 'watch[.]sh /tmp/prl-'
set -u

# Files are the channel now, not a fallback, so polling is how a round trip
# actually completes. A few stat calls cost nothing; waiting a minute to notice
# a report that is already on disk costs a round.
INTERVAL=15
TIMEOUT=900
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
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
    echo "TIMEOUT $TIMEOUT"
    exit 3
  fi
  sleep "$INTERVAL"
done
