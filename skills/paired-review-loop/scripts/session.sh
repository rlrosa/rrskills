#!/usr/bin/env bash
# session.sh — create and maintain a paired-review-loop session directory.
#
#   session.sh init <session-dir>
#       Create <session-dir>/evidence/ and a session.env holding what both
#       agents need to find each other.
#
#   session.sh register <session-dir> <thinker|worker>
#       Record the calling pane as that role's pane, read from $TMUX_PANE.
#       Use this when the two agents were started by hand; spawn-worker.sh
#       registers both panes on its own.
#
#   session.sh get <session-dir> <key>
#       Print one value, e.g. `session.sh get /tmp/prl-demo PRL_WORKER_PANE`.
#       Prints nothing and exits 1 when the key is unset.
#
# session.env is plain `KEY='value'` lines, so it can be sourced directly:
#   PRL_SESSION_DIR, PRL_THINKER_PANE, PRL_WORKER_PANE, PRL_WORKER_CMD,
#   PRL_WORKER_CWD
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# Print the header comment as the help text, stopping at the first line of code.
# Reading where the block ends rather than hardcoding a line range keeps the two
# from drifting apart when the header grows.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

VERB="${1:-}"
[ -z "$VERB" ] && usage 1

case "$VERB" in
  init)
    SESSION="${2:?usage: session.sh init <session-dir>}"
    mkdir -p "$SESSION/evidence"
    SESSION=$(cd "$SESSION" && pwd)
    prl_set_key "$SESSION/session.env" PRL_SESSION_DIR "$SESSION"
    echo "$SESSION"
    ;;

  register)
    SESSION="${2:?usage: session.sh register <session-dir> <thinker|worker>}"
    ROLE="${3:?usage: session.sh register <session-dir> <thinker|worker>}"
    if [ ! -d "$SESSION" ]; then
      echo "session: no such session dir: $SESSION" >&2
      exit 1
    fi
    if [ -z "${TMUX_PANE:-}" ]; then
      echo "session: \$TMUX_PANE is unset, so this process is not in a tmux pane" >&2
      exit 10
    fi
    case "$ROLE" in
      thinker) KEY=PRL_THINKER_PANE ;;
      worker) KEY=PRL_WORKER_PANE ;;
      *)
        echo "session: role must be 'thinker' or 'worker', got '$ROLE'" >&2
        exit 2
        ;;
    esac
    prl_set_key "$SESSION/session.env" "$KEY" "$TMUX_PANE"
    echo "$KEY=$TMUX_PANE"
    ;;

  get)
    SESSION="${2:?usage: session.sh get <session-dir> <key>}"
    KEY="${3:?usage: session.sh get <session-dir> <key>}"
    ENV_FILE="$SESSION/session.env"
    [ -f "$ENV_FILE" ] || exit 1
    # Source in a subshell so the caller's environment is untouched.
    value=$(
      # shellcheck disable=SC1090
      . "$ENV_FILE" 2>/dev/null
      eval "printf '%s' \"\${$KEY:-}\""
    )
    [ -z "$value" ] && exit 1
    printf '%s\n' "$value"
    ;;

  -h | --help | help)
    usage 0
    ;;

  *)
    echo "session: unknown verb '$VERB'" >&2
    usage 2
    ;;
esac
