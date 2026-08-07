#!/usr/bin/env bash
# watch.sh <file> [file...] [--interval <seconds>]
#
# Blocks until one of the files changes (its mtime increases, or it first
# appears), then prints "CHANGED <file> <mtime>" and exits 0. Run it
# backgrounded so your harness re-invokes you when it exits:
#   scripts/watch.sh /tmp/prl-demo/members/*/out &
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
# This is the fallback wake-up. When the agents run in tmux panes, notify.sh
# wakes them at once and no watcher is needed at all - see TMUX.md. Use this
# when there is no tmux, or when notify.sh reports it could not reach someone.
#
# Rules:
#   - Keep exactly ONE watcher armed at a time.
#   - Default poll interval is 60s; pass --interval to change it.
#   - To replace an old watcher without the pkill matching ITSELF, use a regex
#     with [.] for the literal dot:   pkill -f 'watch[.]sh /tmp/prl-'
set -u

INTERVAL=60
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    -h | --help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0
      ;;
    *) FILES+=("$1"); shift ;;
  esac
done

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "usage: watch.sh <file> [file...] [--interval <seconds>]" >&2
  exit 2
fi

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

while true; do
  for index in "${!FILES[@]}"; do
    current=$(mtime_of "${FILES[$index]}")
    if [ "$current" -gt "${baselines[$index]}" ]; then
      echo "CHANGED ${FILES[$index]} $current"
      exit 0
    fi
  done
  sleep "$INTERVAL"
done
