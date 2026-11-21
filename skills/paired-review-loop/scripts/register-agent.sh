#!/usr/bin/env bash
# register-agent.sh <session-dir> <name> <agent-pid>
#
# Record the ACTUAL agent process for a member: its pid and /proc start time,
# written to <session>/broker/agents/<name>.  The roster already ties the
# member to a pane, but a pane holds a shell that can run any number of
# processes over its life; only the pid + start time pins down the exact
# process the broker is allowed to wake.
#
# With an identity recorded, the broker refuses to type into the pane once the
# pane's foreground process is no longer that exact process — the agent exited
# back to a shell, or was restarted — and tells the other side.  Without one,
# the broker falls back to the pane-level checks (registered pane, not a
# shell, matching agent name).
#
# Run it from the agent's own tooling once the agent is up, with the agent
# process's own pid — from a command the agent runs, that is simply `$$`:
#   register-agent.sh <session> <name> $$
# The broker then refuses to type into the pane once that exact process has
# exited or been replaced (a pid reuse is ruled out by the /proc start
# time), and tells the other side.
#
# register-agent.sh --forget <session-dir> <name>
#   Normal unregister: remove the recorded identity.
#
# Exit 0 on success, 2 on bad usage, 1 when the pid is not running.
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

if [ "${1:-}" = "--forget" ]; then
  shift
  [ $# -eq 2 ] || usage 2
  SESSION="$1"
  NAME="$2"
  [ -d "$SESSION" ] || { echo "register-agent: no such session dir: $SESSION" >&2; exit 1; }
  SESSION=$(cd "$SESSION" && pwd)
  prl_assert_session_owner "$SESSION" || exit 4
  case "$NAME" in
    *[!A-Za-z0-9_-]*)
      echo "register-agent: member name must be letters, digits, dash or underscore (got '$NAME')" >&2
      exit 2
      ;;
  esac
  AGENT_FILE="$SESSION/broker/agents/$NAME"
  if [ -f "$AGENT_FILE" ]; then
    rm -f "$AGENT_FILE"
    echo "forgot agent identity for '$NAME'"
  else
    echo "no recorded agent identity for '$NAME'"
  fi
  exit 0
fi

[ $# -eq 3 ] || usage 2
SESSION="$1"
NAME="$2"
PID="$3"

[ -d "$SESSION" ] || { echo "register-agent: no such session dir: $SESSION" >&2; exit 1; }
SESSION=$(cd "$SESSION" && pwd)
prl_assert_session_owner "$SESSION" || exit 4

case "$NAME" in
  *[!A-Za-z0-9_-]*)
    echo "register-agent: member name must be letters, digits, dash or underscore (got '$NAME')" >&2
    exit 2
    ;;
esac
case "$PID" in
  '' | *[!0-9]*)
    echo "register-agent: <agent-pid> must be a pid (got '$PID')" >&2
    exit 2
    ;;
esac
[ -d "/proc/$PID" ] || { echo "register-agent: pid $PID is not running" >&2; exit 1; }

# starttime is /proc/<pid>/stat field 22; the comm field (2) is wrapped in
# parentheses and may contain spaces, so count fields after the last ')'.
STAT=$(cat "/proc/$PID/stat")
REST=${STAT##*)}
# shellcheck disable=SC2086
set -- $REST
# Fields after comm: state is $1 ... starttime is field 22 overall, i.e. the
# 20th word.  $20 would expand as $2 followed by a literal 0, so braces are
# required.
[ $# -ge 20 ] || { echo "register-agent: could not parse /proc/$PID/stat" >&2; exit 1; }
START_TIME="${20}"

AGENT_FILE="$SESSION/broker/agents/$NAME"
mkdir -p "$SESSION/broker/agents"
rewritten="$AGENT_FILE.tmp.$$"
printf '%s %s\n' "$PID" "$START_TIME" > "$rewritten"
mv "$rewritten" "$AGENT_FILE"
echo "registered agent for '$NAME': pid $PID start $START_TIME"