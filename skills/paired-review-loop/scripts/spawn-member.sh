#!/usr/bin/env bash
# spawn-member.sh — open a tmux pane and start one team member in it, already
# told which role it plays, what it is called, and where its mailbox lives.
#
# Usage:
#   spawn-member.sh --session <dir> --name <name> --cmd '<agent command>' [options]
#
#   --session <dir>     Session directory; created if missing.
#   --name <name>       Member name, unique in the session. Becomes its
#                       directory under <session>/members/, so letters, digits,
#                       dash and underscore only. E.g. worker, tester-1.
#   --role <role>       worker (implements, the only member that edits the repo)
#                       or tester (runs things, captures evidence, never judges).
#                       Default: worker.
#   --cmd '<command>'   Agent to launch, passed through verbatim. Include
#                       whatever permission flags you want it to run with:
#                         'claude'
#                         'claude --model claude-sonnet-5'
#                         'codex'
#                         'agy --dangerously-skip-permissions'
#   --cwd <dir>         Working directory for the member (default: current).
#   --into <pane-id>    Pane to split. Defaults to this one ($TMUX_PANE).
#                       spawn-team.sh uses it to gather the whole team into one
#                       window.
#   --layout <where>    Where to put the pane. Named after the result rather
#                       than tmux's -h/-v, which read backwards to most people.
#                       A split falls back to a new window when the window is
#                       too small to divide.
#                         right   side by side, to the right (default)
#                                 aliases: split, horizontal, h
#                         below   stacked, underneath
#                                 aliases: vertical, v
#                         window  a new window of its own
#   --window-name <n>   Name for the window when --layout window is used.
#   --size <n>          Pane size as a percentage of the split, 1-99
#                       (default 50).
#   --skill-prefix <c>  How the member's CLI invokes a skill: '/' for Claude and
#                       AGY, '$' for Codex. Inferred from --cmd when omitted.
#   --skill-name <n>    Skill to invoke (default: paired-review-loop).
#   --no-bootstrap      Launch the agent but send it no instructions, leaving
#                       the first message to you.
#
# Prints the member's pane ID on stdout, adds it to the roster and tags the pane
# with its identity.
#
# Write <session>/members/<name>/in BEFORE spawning: the bootstrap message then
# points the member straight at its first task and it starts on its own.
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# Seconds to wait for the agent's TUI to replace the shell in the new pane.
PRL_SPAWN_TIMEOUT="${PRL_SPAWN_TIMEOUT:-60}"
# How many times to retype the bootstrap while the TUI finishes starting up.
# Each failed attempt costs about a second, so this is also the rough number of
# seconds allowed for the agent to become interactive.
PRL_BOOTSTRAP_ATTEMPTS="${PRL_BOOTSTRAP_ATTEMPTS:-30}"

SESSION=""
MEMBER_NAME=""
MEMBER_ROLE="worker"
AGENT_CMD=""
CWD="$PWD"
INTO_PANE=""
LAYOUT="right"
WINDOW_NAME=""
SIZE_PERCENT=50
SKILL_PREFIX=""
SKILL_NAME="paired-review-loop"
BOOTSTRAP=true

# Print the header comment as the help text, stopping at the first line of code.
# Reading where the block ends rather than hardcoding a line range keeps the two
# from drifting apart when the header grows.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --name) MEMBER_NAME="$2"; shift 2 ;;
    --role) MEMBER_ROLE="$2"; shift 2 ;;
    --cmd) AGENT_CMD="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --into) INTO_PANE="$2"; shift 2 ;;
    --layout) LAYOUT="$2"; shift 2 ;;
    --window-name) WINDOW_NAME="$2"; shift 2 ;;
    --size) SIZE_PERCENT="$2"; shift 2 ;;
    --skill-prefix) SKILL_PREFIX="$2"; shift 2 ;;
    --skill-name) SKILL_NAME="$2"; shift 2 ;;
    --no-bootstrap) BOOTSTRAP=false; shift ;;
    -h | --help) usage 0 ;;
    *)
      echo "spawn-member: unknown option '$1'" >&2
      usage 2
      ;;
  esac
done

[ -n "$SESSION" ] || { echo "spawn-member: --session is required" >&2; exit 2; }
[ -n "$MEMBER_NAME" ] || { echo "spawn-member: --name is required" >&2; exit 2; }
[ -n "$AGENT_CMD" ] || { echo "spawn-member: --cmd is required" >&2; exit 2; }

# Resolve the layout to the tmux flag that produces it. tmux calls a side-by-side
# split "horizontal" (-h) and a stacked one "vertical" (-v), which is the
# opposite of how most people read those words, so accept both vocabularies and
# settle the meaning here.
case "$LAYOUT" in
  right | split | horizontal | h) SPLIT_FLAG="-h" ;;
  below | vertical | v) SPLIT_FLAG="-v" ;;
  window) SPLIT_FLAG="" ;;
  *)
    echo "spawn-member: --layout must be 'right', 'below' or 'window' (got '$LAYOUT')" >&2
    exit 2
    ;;
esac

case "$SIZE_PERCENT" in
  '' | *[!0-9]*)
    echo "spawn-member: --size must be a whole number of percent (got '$SIZE_PERCENT')" >&2
    exit 2
    ;;
esac
if [ "$SIZE_PERCENT" -lt 1 ] || [ "$SIZE_PERCENT" -gt 99 ]; then
  echo "spawn-member: --size must be between 1 and 99 (got '$SIZE_PERCENT')" >&2
  exit 2
fi

if ! prl_tmux_available; then
  echo "spawn-member: no tmux server reachable; start the member by hand" >&2
  exit 10
fi

# The thinker's own pane is the address members ring back on, so there is
# nothing to orchestrate without it.
THINKER_PANE="${TMUX_PANE:-}"
if [ -z "$THINKER_PANE" ]; then
  echo "spawn-member: \$TMUX_PANE is unset, so this process is not in a tmux pane" >&2
  exit 10
fi
[ -n "$INTO_PANE" ] || INTO_PANE="$THINKER_PANE"

SESSION=$("$SCRIPT_DIR/session.sh" init "$SESSION") || exit 1
CWD=$(cd "$CWD" && pwd) || exit 1
MEMBER_DIR="$SESSION/members/$MEMBER_NAME"

# Codex invokes skills with $name; Claude and AGY use /name.
if [ -z "$SKILL_PREFIX" ]; then
  case "$(basename "${AGENT_CMD%% *}")" in
    codex) SKILL_PREFIX='$' ;;
    *) SKILL_PREFIX='/' ;;
  esac
fi

# Split off a pane and print its ID, or print nothing if the window cannot be
# divided.
#
# The size flag changed spelling: tmux 3.1 introduced `-l 40%` and later dropped
# the older `-p 40`, which now fails outright. Try the current spelling and fall
# back to the old one so the script works either side of that change.
split_off_member_pane() {
  tmux split-window "$SPLIT_FLAG" -d -t "$INTO_PANE" -c "$CWD" \
    -l "$SIZE_PERCENT%" -P -F '#{pane_id}' 2>/dev/null && return 0
  tmux split-window "$SPLIT_FLAG" -d -t "$INTO_PANE" -c "$CWD" \
    -p "$SIZE_PERCENT" -P -F '#{pane_id}' 2>/dev/null
}

# Open the pane running a plain shell rather than the agent itself. If the agent
# exits or crashes, the pane stays put with its output on screen instead of
# vanishing, which is the difference between a diagnosable failure and a silent
# one.
MEMBER_PANE=""
if [ -n "$SPLIT_FLAG" ]; then
  MEMBER_PANE=$(split_off_member_pane) || MEMBER_PANE=""
  if [ -z "$MEMBER_PANE" ]; then
    echo "spawn-member: could not split the window (too small?), opening a new window instead" >&2
  fi
fi
if [ -z "$MEMBER_PANE" ]; then
  if [ -n "$WINDOW_NAME" ]; then
    MEMBER_PANE=$(tmux new-window -d -c "$CWD" -n "$WINDOW_NAME" -P -F '#{pane_id}')
  else
    MEMBER_PANE=$(tmux new-window -d -c "$CWD" -P -F '#{pane_id}')
  fi
  [ -n "$MEMBER_PANE" ] || {
    echo "spawn-member: could not create a pane for '$MEMBER_NAME'" >&2
    exit 1
  }
fi

prl_set_key "$SESSION/session.env" PRL_THINKER_PANE "$THINKER_PANE"
# Record and tag before launching. If the agent then fails to start, the member
# still shows up in `roster.sh verify` as a problem to look at, instead of being
# an untracked pane nobody can account for.
"$SCRIPT_DIR/roster.sh" add "$SESSION" "$MEMBER_NAME" "$MEMBER_ROLE" \
  "$MEMBER_PANE" "$CWD" "$AGENT_CMD" > /dev/null || exit 1

# Let the shell in the new pane draw its prompt before typing at it.
sleep 0.5
prl_send_line "$MEMBER_PANE" "$AGENT_CMD"

# The agent is up once it has replaced the shell as the pane's foreground
# command. Waiting for that beats a fixed sleep, which is either too short on a
# cold start or wasted time on a warm one.
deadline=$((SECONDS + PRL_SPAWN_TIMEOUT))
while prl_pane_is_shell "$MEMBER_PANE"; do
  if ! prl_pane_exists "$MEMBER_PANE"; then
    echo "spawn-member: pane $MEMBER_PANE closed before '$AGENT_CMD' started" >&2
    exit 1
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "spawn-member: '$AGENT_CMD' did not start within ${PRL_SPAWN_TIMEOUT}s in pane $MEMBER_PANE" >&2
    echo "spawn-member: the pane is still there - look at it to see what happened" >&2
    echo "$MEMBER_PANE"
    exit 1
  fi
  sleep 1
done

if [ "$BOOTSTRAP" = true ]; then
  # Let the agent finish drawing its opening screen. Typing into a TUI that is
  # still painting gets the characters echoed by the terminal but the Enter
  # thrown away, which parks the bootstrap in the input box unsent.
  prl_wait_ready "$MEMBER_PANE"

  # Point the member at its first task only if there is one. A member told to
  # read a file that does not exist yet will improvise, which is exactly what
  # the protocol is designed to prevent.
  if [ -s "$MEMBER_DIR/in" ]; then
    first_step="Read $MEMBER_DIR/in and begin."
  else
    first_step="The thinker will write $MEMBER_DIR/in shortly; wait for its nudge before starting."
  fi

  role_upper=$(printf '%s' "$MEMBER_ROLE" | tr '[:lower:]' '[:upper:]')
  bootstrap="${SKILL_PREFIX}${SKILL_NAME} You are the $role_upper named '$MEMBER_NAME'. Session dir: $SESSION. Your inbox is $MEMBER_DIR/in and you report in $MEMBER_DIR/out. Your pane is $MEMBER_PANE and the thinker's pane is $THINKER_PANE. $first_step"

  # Failing here leaves a live agent that was never told what it is, so treat a
  # bootstrap that would not go through as a failed spawn rather than reporting
  # a member that is not really working.
  if ! prl_send_verified "$MEMBER_PANE" "$bootstrap" "$PRL_BOOTSTRAP_ATTEMPTS"; then
    echo "spawn-member: '$AGENT_CMD' started in $MEMBER_PANE but never accepted the bootstrap" >&2
    echo "spawn-member: the agent is running with no role - send it the bootstrap yourself, or kill the pane" >&2
    echo "$MEMBER_PANE"
    exit 1
  fi
fi

echo "$MEMBER_PANE"
