#!/usr/bin/env bash
# watch.sh <file> [interval_s=60]
#
# Blocks until <file>'s mtime increases (or the file first appears), then prints
# "CHANGED <file> <mtime>" and exits 0. Run it backgrounded so your harness
# re-invokes you when it exits:  scripts/watch.sh /tmp/prl-<id>/worker.out &
#
# This is the fallback wake-up. When both agents run in tmux panes, notify.sh
# wakes the counterpart at once and no watcher is needed at all - see TMUX.md.
# Use this when there is no tmux, or when notify.sh reports it could not reach
# the counterpart.
#
# Rules:
#   - Keep exactly ONE watcher armed at a time.
#   - Default poll interval is 60s; pass a second arg to change it (e.g. 30, 120).
#   - To replace an old watcher without the pkill matching ITSELF, use a regex
#     with [.] for the literal dot:   pkill -f 'watch[.]sh /tmp/prl-'
set -u

FILE="${1:?usage: watch.sh <file> [interval_s]}"
INTERVAL="${2:-60}"

baseline=$(stat -c %Y "$FILE" 2>/dev/null || echo 0)
while true; do
  cur=$(stat -c %Y "$FILE" 2>/dev/null || echo 0)
  if [ "$cur" -gt "$baseline" ]; then
    echo "CHANGED $FILE $cur"
    exit 0
  fi
  sleep "$INTERVAL"
done
