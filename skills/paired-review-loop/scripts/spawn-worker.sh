#!/usr/bin/env bash
# spawn-worker.sh — open a tmux pane next to the thinker and start a worker
# agent in it, already told which role it plays and where the session lives.
#
# Usage:
#   spawn-worker.sh --session <dir> --cmd '<agent command>' [options]
#
#   --session <dir>     Session directory; created if missing.
#   --cmd '<command>'   Agent to launch, passed through verbatim. Include
#                       whatever permission flags you want it to run with:
#                         'claude'
#                         'claude --model claude-sonnet-5'
#                         'codex'
#                         'agy --dangerously-skip-permissions'
#   --cwd <dir>         Working directory for the worker (default: current).
#   --layout split      Split the thinker's window so both panes are visible.
#                       This is the default, and falls back to a new window
#                       when the window is too small to split.
#   --layout window     Always open a new window instead.
#   --skill-prefix <c>  How the worker's CLI invokes a skill: '/' for Claude and
#                       AGY, '$' for Codex. Inferred from --cmd when omitted.
#   --skill-name <n>    Skill to invoke (default: paired-review-loop).
#   --no-bootstrap      Launch the agent but send it no instructions, leaving
#                       the first message to you.
#
# Prints the worker's pane ID on stdout and records both panes in
# <session>/session.env.
#
# Write the first task to <session>/thinker.out BEFORE spawning: the bootstrap
# message then points the worker straight at it and the loop starts on its own.
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
AGENT_CMD=""
CWD="$PWD"
LAYOUT="split"
SKILL_PREFIX=""
SKILL_NAME="paired-review-loop"
BOOTSTRAP=true

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --cmd) AGENT_CMD="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --layout) LAYOUT="$2"; shift 2 ;;
    --skill-prefix) SKILL_PREFIX="$2"; shift 2 ;;
    --skill-name) SKILL_NAME="$2"; shift 2 ;;
    --no-bootstrap) BOOTSTRAP=false; shift ;;
    -h | --help) usage 0 ;;
    *)
      echo "spawn-worker: unknown option '$1'" >&2
      usage 2
      ;;
  esac
done

[ -n "$SESSION" ] || { echo "spawn-worker: --session is required" >&2; exit 2; }
[ -n "$AGENT_CMD" ] || { echo "spawn-worker: --cmd is required" >&2; exit 2; }
case "$LAYOUT" in
  split | window) ;;
  *) echo "spawn-worker: --layout must be 'split' or 'window'" >&2; exit 2 ;;
esac

if ! prl_tmux_available; then
  echo "spawn-worker: no tmux server reachable; start the worker by hand" >&2
  exit 10
fi

# The thinker's own pane is both the pane to split and the address the worker
# will ring back on, so there is nothing to spawn from without it.
THINKER_PANE="${TMUX_PANE:-}"
if [ -z "$THINKER_PANE" ]; then
  echo "spawn-worker: \$TMUX_PANE is unset, so this process is not in a tmux pane" >&2
  exit 10
fi

SESSION=$("$SCRIPT_DIR/session.sh" init "$SESSION") || exit 1
CWD=$(cd "$CWD" && pwd) || exit 1

# Codex invokes skills with $name; Claude and AGY use /name.
if [ -z "$SKILL_PREFIX" ]; then
  case "$(basename "${AGENT_CMD%% *}")" in
    codex) SKILL_PREFIX='$' ;;
    *) SKILL_PREFIX='/' ;;
  esac
fi

# Open the pane running a plain shell rather than the agent itself. If the agent
# exits or crashes, the pane stays put with its output on screen instead of
# vanishing, which is the difference between a diagnosable failure and a silent
# one.
WORKER_PANE=""
if [ "$LAYOUT" = "split" ]; then
  # Target the thinker's pane explicitly. tmux would otherwise split the
  # *active* pane, which is frequently some other pane the human is looking at.
  WORKER_PANE=$(tmux split-window -h -d -t "$THINKER_PANE" -c "$CWD" -P -F '#{pane_id}' 2>/dev/null) || WORKER_PANE=""
  if [ -z "$WORKER_PANE" ]; then
    echo "spawn-worker: could not split the window (too small?), opening a new window instead" >&2
  fi
fi
if [ -z "$WORKER_PANE" ]; then
  WORKER_PANE=$(tmux new-window -d -c "$CWD" -P -F '#{pane_id}') || {
    echo "spawn-worker: could not create a pane for the worker" >&2
    exit 1
  }
fi

ENV_FILE="$SESSION/session.env"
prl_set_key "$ENV_FILE" PRL_THINKER_PANE "$THINKER_PANE"
prl_set_key "$ENV_FILE" PRL_WORKER_PANE "$WORKER_PANE"
prl_set_key "$ENV_FILE" PRL_WORKER_CMD "$AGENT_CMD"
prl_set_key "$ENV_FILE" PRL_WORKER_CWD "$CWD"

# Let the shell in the new pane draw its prompt before typing at it.
sleep 0.5
prl_send_line "$WORKER_PANE" "$AGENT_CMD"

# The agent is up once it has replaced the shell as the pane's foreground
# command. Waiting for that beats a fixed sleep, which is either too short on a
# cold start or wasted time on a warm one.
deadline=$((SECONDS + PRL_SPAWN_TIMEOUT))
while prl_pane_is_shell "$WORKER_PANE"; do
  if ! prl_pane_exists "$WORKER_PANE"; then
    echo "spawn-worker: pane $WORKER_PANE closed before '$AGENT_CMD' started" >&2
    exit 1
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "spawn-worker: '$AGENT_CMD' did not start within ${PRL_SPAWN_TIMEOUT}s in pane $WORKER_PANE" >&2
    echo "spawn-worker: the pane is still there - look at it to see what happened" >&2
    echo "$WORKER_PANE"
    exit 1
  fi
  sleep 1
done

if [ "$BOOTSTRAP" = true ]; then
  # Let the agent finish drawing its opening screen. Typing into a TUI that is
  # still painting gets the characters echoed by the terminal but the Enter
  # thrown away, which parks the bootstrap in the input box unsent.
  prl_wait_ready "$WORKER_PANE"

  # Point the worker at its first task only if there is one. A worker told to
  # read a file that does not exist yet will improvise, which is exactly what
  # the protocol is designed to prevent.
  if [ -s "$SESSION/thinker.out" ]; then
    first_step="Read $SESSION/thinker.out and begin."
  else
    first_step="The thinker will write $SESSION/thinker.out shortly; wait for its nudge before starting."
  fi

  bootstrap="${SKILL_PREFIX}${SKILL_NAME} You are the WORKER. Session dir: $SESSION. Your pane is $WORKER_PANE and the thinker's pane is $THINKER_PANE. $first_step"

  # Failing here leaves a live agent that was never told what it is, so treat a
  # bootstrap that would not go through as a failed spawn rather than reporting
  # a worker that is not really working.
  if ! prl_send_verified "$WORKER_PANE" "$bootstrap" "$PRL_BOOTSTRAP_ATTEMPTS"; then
    echo "spawn-worker: '$AGENT_CMD' started in $WORKER_PANE but never accepted the bootstrap" >&2
    echo "spawn-worker: the agent is running with no role - send it the bootstrap yourself, or kill the pane" >&2
    echo "$WORKER_PANE"
    exit 1
  fi
fi

echo "$WORKER_PANE"
