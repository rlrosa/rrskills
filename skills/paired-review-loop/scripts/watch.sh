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

INTERVAL=60
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

baselines=()
for file in "${FILES[@]}"; do
  baselines+=("$(mtime_of "$file")")
done

deadline=$((SECONDS + TIMEOUT))

while true; do
  for index in "${!FILES[@]}"; do
    current=$(mtime_of "${FILES[$index]}")
    if [ "$current" -gt "${baselines[$index]}" ]; then
      echo "CHANGED ${FILES[$index]} $current"
      exit 0
    fi
  done
  # Check the files once more before giving up, so a write landing during the
  # final sleep is reported as a change rather than as a timeout.
  if [ "$TIMEOUT" -ne 0 ] && [ "$SECONDS" -ge "$deadline" ]; then
    echo "TIMEOUT $TIMEOUT"
    exit 3
  fi
  sleep "$INTERVAL"
done
