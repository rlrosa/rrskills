#!/usr/bin/env bash
# notify.sh <pane-id> <message>
#
# Rings the doorbell on the counterpart agent's tmux pane: types <message> into
# it and presses Enter, so that agent wakes up and acts at once instead of
# waiting for watch.sh to notice a file changed.
#
# <message> is a POINTER, never content. Keep it to one line naming the file to
# read — "prl: thinker.out updated, read /tmp/prl-demo/thinker.out". Task text,
# verdicts and evidence belong in the session files, which stay the record of
# what was asked and what was proven.
#
# Start the message with "prl:" rather than "/", "#" or "!". Agent TUIs treat
# those first characters as mode switches (slash command, memory, shell) and
# would act on the nudge instead of reading it.
#
# Exit codes, so a caller can tell what to do next:
#   0   delivered  - the pane reacted to the keystrokes
#   10  no tmux    - fall back to watch.sh on the counterpart's file
#   11  no pane    - the counterpart's pane is gone; tell the human
#   12  shell      - the pane is at a shell prompt, so its agent has exited.
#                    Nothing was sent. Tell the human; do not retry.
#   13  unconfirmed- keys were sent but the pane did not visibly react
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PANE="${1:?usage: notify.sh <pane-id> <message>}"
MSG="${2:?usage: notify.sh <pane-id> <message>}"

# A newline inside the text would submit the message halfway through and leave
# the rest sitting in the input box, so reject it rather than half-send it.
case "$MSG" in
  *$'\n'*)
    echo "notify: message must be a single line" >&2
    exit 2
    ;;
esac

if ! prl_tmux_available; then
  echo "notify: no tmux server reachable; use watch.sh instead" >&2
  exit 10
fi

if ! prl_pane_exists "$PANE"; then
  echo "notify: pane $PANE does not exist" >&2
  exit 11
fi

if prl_pane_is_shell "$PANE"; then
  echo "notify: pane $PANE is at a shell prompt ($(prl_pane_command "$PANE")) - its agent has exited. Nothing sent." >&2
  exit 12
fi

before=$(prl_capture "$PANE")

if ! prl_send_verified "$PANE" "$MSG"; then
  echo "notify: pane $PANE did not accept the message; it may still be starting up" >&2
  exit 13
fi

sleep "$PRL_REACT_DELAY"
after=$(prl_capture "$PANE")

# A changed pane proves the keystrokes landed and the agent is processing them.
# It does not prove the agent understood the nudge — only the reply on the
# counterpart's file proves that.
if [ "$before" = "$after" ]; then
  echo "notify: sent to $PANE but the pane did not react" >&2
  exit 13
fi

echo "DELIVERED $PANE"
