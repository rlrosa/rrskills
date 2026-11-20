#!/usr/bin/env bash
# broker.sh — opt-in tmux wake broker for a paired-review-loop session.
#
#   broker.sh start --session <dir> [--socket <tmux-socket>]
#       Start the broker for a session.  It watches the session's mailbox
#       files (inotify) and types a one-line pointer into the recipient's
#       registered pane when a mailbox changes, instead of each side arming a
#       recurring watcher.  Refuses to start a second broker for the same
#       session.  The default socket is $TMUX's server, or
#       /tmp/tmux-<uid>/default when run outside tmux.
#
#   broker.sh stop --session <dir>
#       Stop the broker.  Pending wakes survive in state.json and are
#       re-delivered on the next start.
#
#   broker.sh status --session <dir>
#       Show whether the broker is running and what is pending.  Exits 0
#       running, 1 not running (pending work is still printed either way).
#
#   broker.sh log --session <dir> [lines]
#       Tail the broker log.
#
#   broker.sh deregister --session <dir> <name>
#       Tell the broker to stop sending to <name>'s pane and drop its pending
#       wakes.  Use after the agent in the pane was restarted by hand;
#       re-register with 'roster.sh add' and 'roster.sh brief'.
#
# The broker is opt-in: with it not running, the session behaves exactly as
# documented in SKILL.md (watch.sh deadlines).  It never creates panes, never
# restarts agents, and only reaches panes registered in roster.tsv or
# session.env.  See BROKER.md for usage and limitations.
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

# Where this process would look for a tmux server: the one it is inside, or
# the per-user default.  Mirrors prl_tmux_socket_path in lib.sh.
default_socket() {
  if [ -n "${TMUX:-}" ]; then
    printf '%s' "${TMUX%%,*}"
  else
    printf '/tmp/tmux-%s/default' "$(id -u)"
  fi
}

SESSION=""
SOCKET=""
NAME=""
LINES=40
VERB="${1:-}"
[ -z "$VERB" ] && usage 1
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --socket) SOCKET="$2"; shift 2 ;;
    -h | --help) usage 0 ;;
    -*)
      echo "broker: unknown option '$1'" >&2
      usage 2
      ;;
    *)
      case "$VERB" in
        deregister) NAME="$1" ;;
        log) LINES="$1" ;;
        *)
          echo "broker: unexpected argument '$1'" >&2
          usage 2
          ;;
      esac
      shift
      ;;
  esac
done

[ -n "$SESSION" ] || { echo "broker: --session <dir> is required" >&2; exit 2; }
[ -d "$SESSION" ] || { echo "broker: no such session dir: $SESSION" >&2; exit 1; }
SESSION=$(cd "$SESSION" && pwd)
BROKER_DIR="$SESSION/broker"
PIDFILE="$BROKER_DIR/state.json.pid"

# True when the pidfile names a live process.
broker_pid() {
  local pid
  [ -f "$PIDFILE" ] || return 1
  pid=$(tr -d '[:space:]' < "$PIDFILE")
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ -d "/proc/$pid" ] || return 1
  printf '%s' "$pid"
}

case "$VERB" in
  start)
    SOCKET="${SOCKET:-$(default_socket)}"
    mkdir -p "$BROKER_DIR/requests"
    if pid=$(broker_pid); then
      echo "broker: already running for $SESSION (pid $pid); stop it first" >&2
      exit 1
    fi
    rm -f "$PIDFILE"
    setsid nohup python3 "$SCRIPT_DIR/broker.py" run \
      --session "$SESSION" --socket "$SOCKET" \
      >> "$BROKER_DIR/broker.log" 2>&1 < /dev/null &
    # The child writes its pidfile on startup; wait for it rather than
    # guessing whether the start took.
    started=""
    for _ in $(seq 1 50); do
      if pid=$(broker_pid); then
        started="$pid"
        break
      fi
      sleep 0.2
    done
    if [ -z "$started" ]; then
      echo "broker: start failed; the tail of the log:" >&2
      tail -n 20 "$BROKER_DIR/broker.log" >&2 || true
      exit 1
    fi
    echo "broker started (pid $started)  socket $SOCKET"
    ;;

  stop)
    if ! pid=$(broker_pid); then
      rm -f "$PIDFILE"
      echo "broker: not running (stale pidfile removed)"
      exit 0
    fi
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      [ ! -d "/proc/$pid" ] && break
      sleep 0.2
    done
    if [ -d "/proc/$pid" ]; then
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.5
    fi
    rm -f "$PIDFILE"
    echo "broker stopped (pid $pid)"
    ;;

  status)
    python3 "$SCRIPT_DIR/broker.py" status --session "$SESSION"
    ;;

  log)
    [ -f "$BROKER_DIR/broker.log" ] || { echo "broker: no log yet at $BROKER_DIR/broker.log" >&2; exit 1; }
    tail -n "$LINES" "$BROKER_DIR/broker.log"
    ;;

  deregister)
    case "$NAME" in
      '' | *[!A-Za-z0-9_-]*)
        echo "broker: member name must be letters, digits, dash or underscore (got '${NAME}')" >&2
        exit 2
        ;;
    esac
    mkdir -p "$BROKER_DIR/requests"
    printf '%s\n' "$SESSION" > "$BROKER_DIR/requests/request-deregister-$NAME"
    echo "deregistration requested for '$NAME'; the broker applies it on its next scan"
    ;;

  -h | --help | help)
    usage 0
    ;;

  *)
    echo "broker: unknown verb '$VERB'" >&2
    usage 2
    ;;
esac