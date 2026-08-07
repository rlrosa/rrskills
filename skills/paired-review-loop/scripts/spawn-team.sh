#!/usr/bin/env bash
# spawn-team.sh — start a whole team from a roster spec, in one tiled window.
#
# Usage:
#   spawn-team.sh --session <dir> --spec <file> [--cwd <dir>] [--window-name <n>]
#
#   --session <dir>     Session directory; created if missing.
#   --spec <file>       Team definition, one member per line:
#
#                           # name      role     agent
#                           worker      worker   claude --model claude-sonnet-5
#                           tester-1    tester   codex
#                           tester-2    tester   agy --dangerously-skip-permissions
#
#                       Columns are split on whitespace; everything after the
#                       role is the agent command, so it may contain flags and
#                       spaces. Blank lines and # comments are ignored.
#                       Use - for the spec to read it from stdin.
#   --cwd <dir>         Working directory for every member (default: current).
#   --window-name <n>   Window to gather the team into (default: prl-<session>).
#   --no-bootstrap      Launch the agents but send no instructions.
#
# Prints one `name<TAB>pane` line per member.
#
# Write each member's <session>/members/<name>/in BEFORE spawning, and they
# start work as soon as they come up.
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# Past this many panes a tiled window stops being readable, and every extra
# member multiplies the tokens burned per round. Warn rather than refuse; it is
# your terminal and your budget.
PRL_TEAM_WARN_SIZE="${PRL_TEAM_WARN_SIZE:-6}"

SESSION=""
SPEC=""
CWD="$PWD"
WINDOW_NAME=""
BOOTSTRAP_ARGS=()

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --spec) SPEC="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --window-name) WINDOW_NAME="$2"; shift 2 ;;
    --no-bootstrap) BOOTSTRAP_ARGS=(--no-bootstrap); shift ;;
    -h | --help) usage 0 ;;
    *)
      echo "spawn-team: unknown option '$1'" >&2
      usage 2
      ;;
  esac
done

[ -n "$SESSION" ] || { echo "spawn-team: --session is required" >&2; exit 2; }
[ -n "$SPEC" ] || { echo "spawn-team: --spec is required" >&2; exit 2; }

if ! prl_tmux_available; then
  echo "spawn-team: no tmux server reachable; start the members by hand" >&2
  exit 10
fi
if [ -z "${TMUX_PANE:-}" ]; then
  echo "spawn-team: \$TMUX_PANE is unset, so this process is not in a tmux pane" >&2
  exit 10
fi

SESSION=$("$SCRIPT_DIR/session.sh" init "$SESSION") || exit 1
CWD=$(cd "$CWD" && pwd) || exit 1
if [ -z "$WINDOW_NAME" ]; then
  # Session dirs are usually already called prl-something, so only add the
  # prefix when it is missing rather than producing prl-prl-demo.
  WINDOW_NAME=$(basename "$SESSION")
  case "$WINDOW_NAME" in
    prl-*) ;;
    *) WINDOW_NAME="prl-$WINDOW_NAME" ;;
  esac
fi

NAMES=()
ROLES=()
COMMANDS=()
while read -r name role agent; do
  case "$name" in '' | '#'*) continue ;; esac
  if [ -z "$role" ] || [ -z "$agent" ]; then
    echo "spawn-team: '$name' needs a role and an agent command" >&2
    exit 2
  fi
  NAMES+=("$name")
  ROLES+=("$role")
  COMMANDS+=("$agent")
done < <(if [ "$SPEC" = "-" ]; then cat; else cat "$SPEC"; fi)

MEMBER_COUNT=${#NAMES[@]}
if [ "$MEMBER_COUNT" -eq 0 ]; then
  echo "spawn-team: no members in $SPEC" >&2
  exit 2
fi
if [ "$MEMBER_COUNT" -gt "$PRL_TEAM_WARN_SIZE" ]; then
  echo "spawn-team: $MEMBER_COUNT members - panes get hard to read past $PRL_TEAM_WARN_SIZE," \
    "and every member spends tokens every round" >&2
fi

# Spawn one at a time, but give the first member a window of its own and split
# the rest into it, so the team ends up gathered rather than scattered.
#
# Each spawn already waits for its own agent to become interactive, which is the
# bulk of the time. Members later in the list are therefore starting up while
# earlier ones are still being bootstrapped.
FIRST_PANE=""
for index in "${!NAMES[@]}"; do
  name="${NAMES[$index]}"
  spawn_args=(
    --session "$SESSION"
    --name "$name"
    --role "${ROLES[$index]}"
    --cmd "${COMMANDS[$index]}"
    --cwd "$CWD"
  )
  if [ -z "$FIRST_PANE" ]; then
    spawn_args+=(--layout window --window-name "$WINDOW_NAME")
  else
    spawn_args+=(--into "$FIRST_PANE" --layout below)
  fi

  if ! pane=$("$SCRIPT_DIR/spawn-member.sh" "${spawn_args[@]}" "${BOOTSTRAP_ARGS[@]+"${BOOTSTRAP_ARGS[@]}"}"); then
    echo "spawn-team: '$name' failed to start; the members already up are left running" >&2
    echo "spawn-team: check them with 'roster.sh verify $SESSION'" >&2
    exit 1
  fi
  [ -n "$FIRST_PANE" ] || FIRST_PANE="$pane"

  # Re-tile after every split. Splitting the same pane repeatedly would
  # otherwise halve it each time, leaving the first member in a sliver.
  tmux select-layout -t "$pane" tiled > /dev/null 2>&1 || true
  printf '%s\t%s\n' "$name" "$pane"
done
