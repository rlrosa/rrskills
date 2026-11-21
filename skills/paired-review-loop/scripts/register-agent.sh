#!/usr/bin/env bash
# register-agent.sh <session-dir> <name> [<agent-pid>]
#
# Record the ACTUAL agent process for a member: its pid and /proc start time,
# written to <session>/broker/agents/<name>.  The roster already ties the
# member to a pane, but a pane holds a shell that can run any number of
# processes over its life; only the pid + start time pins down the exact
# process the broker is allowed to wake.
#
# With an identity recorded, the broker refuses to type into the pane once
# that exact process has exited or been replaced (a pid reuse is ruled out by
# the /proc start time) — the agent exited back to a shell, or was restarted
# — and tells the other side.  Without one, the broker falls back to the
# pane-level checks (registered pane, not a shell, matching agent name).
#
# With no <agent-pid>, the agent is found from this shell's own ancestry:
# the tmux pane's shell is the root (TMUX_PANE names the pane, pane_pid its
# shell), and the agent is the pane-shell's child in the chain from this
# shell up.  That is the right answer from an agent's tool shell, where `$$`
# is the tool's bash, not the agent:
#   register-agent.sh <session> <name>
# Run it from a command the agent executes.  With an explicit <agent-pid>,
# that pid is recorded as-is.
#
# register-agent.sh --forget <session-dir> <name>
#   Normal unregister: remove the recorded identity.
#
# Exit 0 on success, 2 on bad usage, 1 when the pid is not running or the
# agent cannot be resolved.
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

[ $# -eq 2 ] || [ $# -eq 3 ] || usage 2
SESSION="$1"
NAME="$2"
PID="${3:-}"

[ -d "$SESSION" ] || { echo "register-agent: no such session dir: $SESSION" >&2; exit 1; }
SESSION=$(cd "$SESSION" && pwd)
prl_assert_session_owner "$SESSION" || exit 4

case "$NAME" in
  *[!A-Za-z0-9_-]*)
    echo "register-agent: member name must be letters, digits, dash or underscore (got '$NAME')" >&2
    exit 2
    ;;
esac

# The parent pid from /proc/<pid>/stat: field 4, i.e. the second word after
# the closing ')' (comm may contain spaces and parentheses).
proc_ppid() {
  local stat rest
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  rest=${stat##*)}
  # shellcheck disable=SC2086
  set -- $rest
  [ -n "${2:-}" ] && [ "$2" -ge 1 ] 2>/dev/null || return 1
  printf '%s' "$2"
}

if [ -z "$PID" ]; then
  # Auto mode: the agent is the pane shell's child in this shell's ancestry.
  # TMUX_PANE is inherited down from the pane's shell, so it names the pane
  # this command is running in.
  [ -n "${TMUX_PANE:-}" ] || {
    echo "register-agent: TMUX_PANE is not set; run this from inside the member's pane, or pass an explicit <agent-pid>" >&2
    exit 1
  }
  # display-message -p -t <pane> is the reliable single-pane query on tmux
  # 3.4 (list-panes -t <pane-id> ignores the filter and lists everything).
  PANE_SHELL=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}')
  case "$PANE_SHELL" in
    '' | *[!0-9]*)
      echo "register-agent: pane $TMUX_PANE not found on the tmux server" >&2
      exit 1
      ;;
  esac
  PID=$$
  PARENT=$(proc_ppid "$PID") || {
    echo "register-agent: pid $$ vanished while resolving the agent" >&2
    exit 1
  }
  if [ "$PARENT" = "$PANE_SHELL" ]; then
    echo "register-agent: this shell is a direct child of the pane's shell, so there is no agent process to pin; the pane-level checks apply" >&2
    exit 1
  fi
  while [ "$PARENT" != "$PANE_SHELL" ]; do
    PID=$PARENT
    PARENT=$(proc_ppid "$PID") || {
      echo "register-agent: pid $PID vanished while resolving the agent" >&2
      exit 1
    }
    if [ "$PID" = "$PANE_SHELL" ] || [ "$PARENT" -le 1 ] 2>/dev/null; then
      echo "register-agent: the ancestry left the pane without finding an agent process" >&2
      exit 1
    fi
  done
  echo "resolved agent $PID (child of pane shell $PANE_SHELL in pane $TMUX_PANE)"
fi

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