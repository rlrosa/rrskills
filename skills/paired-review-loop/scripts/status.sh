#!/usr/bin/env bash
# status.sh <session-dir>
#
# Says whose move it is, for every member, from what is on disk.
#
# Use this the moment a wait times out, before deciding anything. The stall this
# exists for is both sides believing the other owes a reply while neither is
# waiting for anything, and an agent cannot detect that by consulting its own
# memory — its memory is the thing that is wrong. The mailbox timestamps are
# not.
#
#   in newer than out, or no out yet  ->  that MEMBER owes a reply
#   out newer than in                 ->  the THINKER owes the next task
#
# Columns: who owes, how long it has been their move, and the pane state that
# roster.sh verify reports.
#
#   member     owes      since  pane     note
#   worker     thinker   3m     OK       replied; you owe the next task
#   tester-1   tester-1  22m    WAITING  frozen with its task unanswered
#
# Exit 0 when nothing needs attention, 1 when something does: a move older than
# PRL_STALL_AFTER (default 600s), or a pane that is not OK.
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# How long a member's move may go unanswered before it counts as stuck rather
# than merely slow.
PRL_STALL_AFTER="${PRL_STALL_AFTER:-600}"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

case "${1:-}" in
  '' ) usage 2 ;;
  -h | --help) usage 0 ;;
esac

SESSION="$1"
[ -d "$SESSION" ] || { echo "status: no such session dir: $SESSION" >&2; exit 1; }
SESSION=$(cd "$SESSION" && pwd)

mtime_of() {
  stat -c %Y "$1" 2>/dev/null || echo 0
}

# Render a duration the way a human reads it while scanning for the outlier.
humanise_seconds() {
  local seconds="$1"
  if [ "$seconds" -lt 60 ]; then
    printf '%ds' "$seconds"
  elif [ "$seconds" -lt 3600 ]; then
    printf '%dm' "$((seconds / 60))"
  else
    printf '%dh%dm' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
  fi
}

# Ask roster.sh for the pane states rather than re-deriving them, so the two
# commands can never disagree about whether a member is alive.
declare -A pane_state=()
while read -r state name _rest; do
  [ -z "$state" ] && continue
  pane_state[$name]="$state"
done < <("$SCRIPT_DIR/roster.sh" verify "$SESSION" 2>/dev/null | sed 's/(.*//')

members=$("$SCRIPT_DIR/roster.sh" list "$SESSION" 2>/dev/null | cut -f1)
if [ -z "$members" ]; then
  echo "status: no members in $SESSION - nobody to be waiting for" >&2
  exit 1
fi

needs_attention=0
now=$(date +%s)
printf '%-12s %-10s %-6s %-9s %s\n' member owes since pane note

while read -r name; do
  [ -z "$name" ] && continue
  inbox="$SESSION/members/$name/in"
  outbox="$SESSION/members/$name/out"
  inbox_time=$(mtime_of "$inbox")
  outbox_time=$(mtime_of "$outbox")
  state="${pane_state[$name]:-UNKNOWN}"

  if [ "$inbox_time" -eq 0 ] && [ "$outbox_time" -eq 0 ]; then
    owes="thinker"
    since=0
    note="no task written yet; you owe the first one"
  elif [ "$outbox_time" -gt "$inbox_time" ]; then
    owes="thinker"
    since=$((now - outbox_time))
    note="replied; you owe the next task"
  else
    owes="$name"
    since=$((now - inbox_time))
    note="has the task; owes a reply"
  fi

  # A member sitting on an approval prompt is stuck no matter how recent its
  # task is, so let the pane state override the clock.
  if [ "$state" != "OK" ] && [ "$state" != "UNKNOWN" ]; then
    needs_attention=1
    case "$state" in
      WAITING) note="frozen with its task unanswered" ;;
      EXITED) note="its agent quit; nothing will answer" ;;
      GONE) note="its pane was closed" ;;
      MISMATCH) note="its pane now belongs to someone else" ;;
    esac
  elif [ "$since" -ge "$PRL_STALL_AFTER" ]; then
    needs_attention=1
    note="$note - stuck for $(humanise_seconds "$since")"
  fi

  printf '%-12s %-10s %-6s %-9s %s\n' \
    "$name" "$owes" "$(humanise_seconds "$since")" "$state" "$note"
done <<< "$members"

exit "$needs_attention"
