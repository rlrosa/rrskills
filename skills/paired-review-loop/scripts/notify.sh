#!/usr/bin/env bash
# notify.sh --session <dir> --member <name> <message>
# notify.sh --session <dir> --role <role> <message>
#
# Pokes a member that has gone quiet: types <message> into its pane and presses
# Enter, so it wakes up instead of waiting for its own deadline.
#
# **You can only reach members the human registered.** There is deliberately no
# way to name a raw pane ID here. Every send resolves through the roster, and
# the roster only contains panes a human created and handed over, so a pane
# nobody registered is unreachable rather than merely discouraged. Resolving
# also makes the pane confirm it really is that member before anything is
# typed, which is what stops a message landing in the wrong terminal after
# panes have been closed or reused.
#
# --role rings every member holding that role, e.g. all the testers. It reports
# per member and exits non-zero if any of them could not be reached.
#
# <message> is a POINTER, never content. Keep it to one line naming the file to
# read — "prl: your inbox was updated, read /tmp/prl-demo/members/worker/in".
# Task text, verdicts and evidence belong in the session files, which stay the
# record of what was asked and what was proven.
#
# Start the message with "prl:" rather than "/", "#" or "!". Agent TUIs treat
# those first characters as mode switches (slash command, memory, shell) and
# would act on the nudge instead of reading it.
#
# Exit codes, so a caller can tell what to do next:
#   0   sent. The word on stdout says how much is actually known:
#         ACCEPTED  - the keystrokes landed and the pane is now working
#         DELIVERED - the keystrokes landed but the pane went idle again. It may
#                     not have picked the message up; watch its out file.
#         QUEUED    - sent to a pane that could not show whether it took, either
#                     because it was mid-turn or too narrow. Its own wait
#                     deadline is the backstop.
#       None of these mean the message was understood. Only that member's own
#       out file proves that.
#   10  no tmux    - fall back to watch.sh on the teammate's file
#   11  no pane    - the teammate's pane is gone; tell the human
#   12  shell      - the pane is at a shell prompt, so its agent has exited.
#                    Nothing was sent. Tell the human; do not retry.
#   13  unconfirmed- keys were sent but the pane did not visibly react
#   14  wrong pane - the pane says it is someone else. The roster is stale;
#                    nothing was sent. Run 'roster.sh sync' and look before
#                    trying again.
#   15  occupied   - the pane's input line holds unsent text, most likely a
#                    human midway through a sentence. Nothing was sent, because
#                    Enter would have submitted their fragment too. --force
#                    overrides.
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

SESSION=""
MEMBER=""
ROLE=""
MSG=""
FORCE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --member) MEMBER="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    -h | --help) usage 0 ;;
    --*)
      echo "notify: unknown option '$1'" >&2
      usage 2
      ;;
    *)
      MSG="$1"
      shift
      ;;
  esac
done

if [ -z "$MEMBER" ] && [ -z "$ROLE" ]; then
  echo "notify: name who to poke with --member <name> or --role <role>." >&2
  echo "notify: raw pane IDs are not accepted - a pane is only reachable once a" >&2
  echo "notify: human has registered it with 'roster.sh add'." >&2
  exit 2
fi
[ -n "$SESSION" ] || { echo "notify: --session is required" >&2; exit 2; }
prl_assert_session_owner "$SESSION" || exit 4

[ -n "$MSG" ] || usage 2

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

# Ring one pane. <label> names the recipient in messages, so a broadcast reads
# as "tester-2" rather than "%183".
ring_pane() {
  local pane="$1" label="$2" before after

  if ! prl_pane_exists "$pane"; then
    echo "notify: $label: pane $pane does not exist" >&2
    return 11
  fi

  if prl_pane_is_shell "$pane"; then
    echo "notify: $label: pane $pane is at a shell prompt ($(prl_pane_command "$pane")) - its agent has exited. Nothing sent." >&2
    return 12
  fi

  # Never press Enter on a line somebody else is composing.
  if [ "$FORCE" != "true" ] && prl_pane_input_occupied "$pane"; then
    echo "notify: $label: pane $pane has unsent text in its input line. Nothing sent." >&2
    echo "notify: pressing Enter there would submit whatever is half-written along with" >&2
    echo "notify: this message, starting work on an instruction nobody finished. Wait, or" >&2
    echo "notify: clear the line yourself, or pass --force if you know it is safe." >&2
    return 15
  fi

  before=$(prl_capture "$pane")

  prl_send_verified "$pane" "$MSG"
  local send_status=$?
  if [ "$send_status" -eq 1 ]; then
    echo "notify: $label: pane $pane did not accept the message; it may still be starting up" >&2
    return 13
  fi
  if [ "$send_status" -eq 2 ]; then
    # The keystrokes went out, but this pane cannot show whether they took. Say
    # which of the two reasons it was, so a pane that is merely busy is not
    # confused with one that is too narrow to talk to at all.
    echo "QUEUED $label $pane (${PRL_UNVERIFIED_REASON:-unverified}; delivery not confirmed)"
    return 0
  fi

  sleep "$PRL_REACT_DELAY"
  after=$(prl_capture "$pane")

  if [ "$before" = "$after" ]; then
    echo "notify: $label: sent to $pane but the pane did not react" >&2
    return 13
  fi

  # Delivered says the keystrokes landed. It does not say the agent picked the
  # message up — one member showed DELIVERED and then sat seventeen minutes
  # without touching its file. So look once more for the pane actually working,
  # and only claim ACCEPTED when it is.
  if prl_pane_is_busy "$pane"; then
    echo "ACCEPTED $label $pane (it is working now)"
  else
    echo "DELIVERED $label $pane (idle after the nudge - watch its out file, not this line)"
  fi
}

# Look a member up and make its pane agree it is that member before sending.
ring_member() {
  local name="$1" pane resolve_status
  pane=$("$SCRIPT_DIR/roster.sh" resolve "$SESSION" "$name")
  resolve_status=$?
  if [ "$resolve_status" -ne 0 ]; then
    return "$resolve_status"
  fi
  ring_pane "$pane" "$name"
}

if [ -n "$ROLE" ]; then
  members=$("$SCRIPT_DIR/roster.sh" list "$SESSION" "$ROLE" | cut -f1)
  if [ -z "$members" ]; then
    echo "notify: no members with role '$ROLE' in $SESSION" >&2
    exit 1
  fi
  worst=0
  while read -r name; do
    [ -z "$name" ] && continue
    ring_member "$name" || worst=$?
  done <<< "$members"
  exit "$worst"
else
  ring_member "$MEMBER"
  exit $?
fi
