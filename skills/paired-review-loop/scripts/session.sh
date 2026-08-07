#!/usr/bin/env bash
# session.sh — create and maintain a paired-review-loop session directory.
#
#   session.sh init <session-dir>
#       Create the session tree and a session.env holding what the team needs
#       to find each other:
#           session.env             the thinker's pane
#           roster.tsv              who is on the team and where
#           members/<name>/in       thinker -> that member
#           members/<name>/out      that member -> thinker
#           members/<name>/evidence raw proof, one file per claim
#
#   session.sh register <session-dir> thinker
#       Record the calling pane as the thinker's, read from $TMUX_PANE. Use
#       this when the thinker did not spawn the team itself. Members register
#       through roster.sh, which also tags their pane.
#
#   session.sh get <session-dir> <key>
#       Print one value, e.g. `session.sh get /tmp/prl-demo PRL_THINKER_PANE`.
#       Prints nothing and exits 1 when the key is unset.
#
# session.env is plain `KEY='value'` lines, so it can be sourced directly:
#   PRL_SESSION_DIR, PRL_THINKER_PANE
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
    mkdir -p "$SESSION/members"
    SESSION=$(cd "$SESSION" && pwd)
    prl_set_key "$SESSION/session.env" PRL_SESSION_DIR "$SESSION"
    "$SCRIPT_DIR/roster.sh" init "$SESSION" > /dev/null
    echo "$SESSION"
    ;;

  register)
    SESSION="${2:?usage: session.sh register <session-dir> thinker}"
    ROLE="${3:?usage: session.sh register <session-dir> thinker}"
    if [ ! -d "$SESSION" ]; then
      echo "session: no such session dir: $SESSION" >&2
      exit 1
    fi
    if [ -z "${TMUX_PANE:-}" ]; then
      echo "session: \$TMUX_PANE is unset, so this process is not in a tmux pane" >&2
      exit 10
    fi
    if [ "$ROLE" != "thinker" ]; then
      echo "session: only the thinker registers here; members use 'roster.sh add'" >&2
      echo "session: e.g. roster.sh add $SESSION <name> <role> \$TMUX_PANE \$PWD '<agent>'" >&2
      exit 2
    fi
    prl_set_key "$SESSION/session.env" PRL_THINKER_PANE "$TMUX_PANE"
    echo "PRL_THINKER_PANE=$TMUX_PANE"
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
