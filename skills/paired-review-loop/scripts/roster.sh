#!/usr/bin/env bash
# roster.sh — the index of who is on the team and which pane each one is in.
#
#   roster.sh init <session-dir>
#       Create an empty roster.
#
#   roster.sh add <session-dir> <name> <role> <pane> <cwd> <agent-command>
#       Register a pane a HUMAN created and handed over. This skill never makes
#       panes; the roster is the list of the ones it is allowed to touch, so a
#       pane that is not in it cannot be reached at all. Replaces any existing
#       row with the same name, and tags the pane with its identity.
#
#   roster.sh brief <session-dir> <name>
#       Tell a registered member which role it is playing and where its mailbox
#       is, by typing into the pane you registered for it. Use once, after the
#       human has started an agent there.
#
#   roster.sh kick <session-dir> <name>
#       Make sure a member is actually working on its inbox, and prove it.
#       Leaves a busy member alone; resumes a parked codex goal; otherwise
#       nudges. Then it presses Enter until the pane is really working, because
#       a send-keys that exits 0 proves nothing - the Enter is routinely
#       swallowed and the command sits visibly unsent. Exits non-zero rather
#       than let you report a member as running when it is not.
#
#   roster.sh list <session-dir> [role]
#       Print the roster, optionally only the members holding one role.
#
#   roster.sh get <session-dir> <name> <name|role|agent|pane|cwd>
#       Print one field. Exits 1 when the member is unknown.
#
#   roster.sh resolve <session-dir> <name>
#       Print the member's pane ID, but only after confirming the pane agrees
#       it is that member. Every send should go through this.
#       Exits 1 unknown member, 11 pane gone, 14 the pane is someone else.
#
#   roster.sh sync <session-dir>
#       Rebuild the roster from the tagged panes that are actually alive. Use
#       after losing or corrupting the file, or when panes were moved by hand.
#
#   roster.sh verify <session-dir>
#       Report the state of every member. Exits 1 if any need attention.
#           OK        working, or done and waiting for its next task
#           WAITING   frozen with its task unanswered - almost always stopped
#                     on an approval prompt nobody is watching
#           EXITED    its agent quit; the pane is back at a shell
#           GONE      its pane was closed
#           MISMATCH  its pane now belongs to a different member
#           AGENT     its pane is running a different agent than recorded
#           UNLISTED  a pane tagged for this session that the roster forgot
#       Telling WAITING from OK needs a moment to see whether the pane is
#       redrawing; set PRL_VERIFY_SAMPLE=0 to skip that and never report it.
#
# roster.tsv is tab-separated `name role agent pane cwd`, one member per line,
# with a comment header. The panes carry the same facts as tmux options
# (@prl_session, @prl_member, @prl_role, @prl_cmd), so neither copy is trusted
# alone.
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# Print the header comment as the help text, stopping at the first line of code.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

ROSTER_HEADER=$'# name\trole\tagent\tpane\tcwd'

# Seconds `verify` watches a pane to see whether it is redrawing. Long enough to
# catch a once-a-second status counter; 0 turns the check off, which makes
# verify instant but unable to tell a stalled member from a busy one.
PRL_VERIFY_SAMPLE="${PRL_VERIFY_SAMPLE:-2}"

roster_path() {
  printf '%s/roster.tsv' "$1"
}

require_roster() {
  prl_assert_session_owner "$1" || exit 4
  local file
  file=$(roster_path "$1")
  if [ ! -f "$file" ]; then
    echo "roster: no roster at $file - run 'roster.sh init $1' first" >&2
    exit 1
  fi
  printf '%s' "$file"
}

# Print a member's row, or nothing when there is no such member.
roster_row() {
  local file="$1" name="$2"
  awk -F'\t' -v name="$name" '!/^#/ && $1 == name { print; exit }' "$file"
}

VERB="${1:-}"
[ -z "$VERB" ] && usage 1

case "$VERB" in
  init)
    SESSION="${2:?usage: roster.sh init <session-dir>}"
    mkdir -p "$SESSION"
    SESSION=$(cd "$SESSION" && pwd)
    ROSTER=$(roster_path "$SESSION")
    [ -f "$ROSTER" ] || printf '%s\n' "$ROSTER_HEADER" > "$ROSTER"
    echo "$ROSTER"
    ;;

  add)
    SESSION="${2:?usage: roster.sh add <session-dir> <name> <role> <pane> <cwd> <agent-command>}"
    NAME="${3:?missing <name>}"
    ROLE="${4:?missing <role>}"
    PANE="${5:?missing <pane>}"
    MEMBER_CWD="${6:?missing <cwd>}"
    AGENT_CMD="${7:?missing <agent-command>}"
    SESSION=$(cd "$SESSION" && pwd)
    ROSTER=$(roster_path "$SESSION")
    [ -f "$ROSTER" ] || printf '%s\n' "$ROSTER_HEADER" > "$ROSTER"

    # A tab in any field would shift every later column when the row is read
    # back, so reject one rather than write a row that parses wrong.
    case "$NAME$ROLE$PANE$MEMBER_CWD$AGENT_CMD" in
      *$'\t'* | *$'\n'*)
        echo "roster: fields must not contain tabs or newlines" >&2
        exit 2
        ;;
    esac
    case "$NAME" in
      *[!A-Za-z0-9_-]*)
        echo "roster: member name '$NAME' must be letters, digits, dash or underscore" >&2
        echo "roster: it becomes a directory under $SESSION/members/" >&2
        exit 2
        ;;
    esac

    rewritten="$ROSTER.tmp.$$"
    awk -F'\t' -v name="$NAME" '/^#/ || $1 != name' "$ROSTER" > "$rewritten"
    printf '%s\t%s\t%s\t%s\t%s\n' "$NAME" "$ROLE" "$AGENT_CMD" "$PANE" "$MEMBER_CWD" >> "$rewritten"
    mv "$rewritten" "$ROSTER"

    mkdir -p "$SESSION/members/$NAME/evidence"
    prl_tag_pane "$PANE" "$SESSION" "$NAME" "$ROLE" "$AGENT_CMD" ||
      echo "roster: recorded '$NAME' but could not tag pane $PANE" >&2
    echo "$NAME	$ROLE	$PANE"
    ;;

  list)
    SESSION="${2:?usage: roster.sh list <session-dir> [role]}"
    ROSTER=$(require_roster "$SESSION")
    WANTED_ROLE="${3:-}"
    awk -F'\t' -v role="$WANTED_ROLE" '!/^#/ && NF && (role == "" || $2 == role)' "$ROSTER"
    ;;

  get)
    SESSION="${2:?usage: roster.sh get <session-dir> <name> <field>}"
    NAME="${3:?missing <name>}"
    FIELD="${4:?missing <field>}"
    ROSTER=$(require_roster "$SESSION")
    case "$FIELD" in
      name) COLUMN=1 ;;
      role) COLUMN=2 ;;
      agent) COLUMN=3 ;;
      pane) COLUMN=4 ;;
      cwd) COLUMN=5 ;;
      *)
        echo "roster: field must be name, role, agent, pane or cwd (got '$FIELD')" >&2
        exit 2
        ;;
    esac
    row=$(roster_row "$ROSTER" "$NAME")
    if [ -z "$row" ]; then
      echo "roster: no member named '$NAME' in $ROSTER" >&2
      exit 1
    fi
    printf '%s\n' "$row" | cut -f "$COLUMN"
    ;;

  resolve)
    SESSION="${2:?usage: roster.sh resolve <session-dir> <name>}"
    NAME="${3:?missing <name>}"
    SESSION=$(cd "$SESSION" && pwd)
    ROSTER=$(require_roster "$SESSION")
    row=$(roster_row "$ROSTER" "$NAME")
    if [ -z "$row" ]; then
      echo "roster: no member named '$NAME' in $ROSTER" >&2
      exit 1
    fi
    PANE=$(printf '%s' "$row" | cut -f4)
    if ! prl_pane_exists "$PANE"; then
      echo "roster: '$NAME' was in pane $PANE, which no longer exists" >&2
      exit 11
    fi
    # The pane has the final say on who it is. Trusting the file alone is how a
    # task ends up in the wrong agent's terminal after panes have been closed,
    # reopened or reused.
    ACTUAL=$(prl_pane_tag "$PANE" prl_member)
    if [ "$ACTUAL" != "$NAME" ]; then
      echo "roster: pane $PANE is '${ACTUAL:-untagged}', not '$NAME' - the roster is stale" >&2
      echo "roster: run 'roster.sh sync $SESSION' and check the team before sending anything" >&2
      exit 14
    fi
    printf '%s\n' "$PANE"
    ;;

  brief)
    SESSION="${2:?usage: roster.sh brief <session-dir> <name>}"
    NAME="${3:?missing <name>}"
    SESSION=$(cd "$SESSION" && pwd)
    ROSTER=$(require_roster "$SESSION")
    row=$(roster_row "$ROSTER" "$NAME")
    if [ -z "$row" ]; then
      echo "roster: no member named '$NAME' in $ROSTER" >&2
      exit 1
    fi
    ROLE=$(printf '%s' "$row" | cut -f2)
    AGENT_CMD=$(printf '%s' "$row" | cut -f3)
    PANE=$("$SCRIPT_DIR/roster.sh" resolve "$SESSION" "$NAME") || exit $?

    MEMBER_DIR="$SESSION/members/$NAME"
    THINKER_PANE=$("$SCRIPT_DIR/session.sh" get "$SESSION" PRL_THINKER_PANE 2>/dev/null || echo unknown)

    # Codex invokes skills with $name; Claude and AGY use /name.
    case "$(basename "${AGENT_CMD%% *}")" in
      codex) SKILL_PREFIX='$' ;;
      *) SKILL_PREFIX='/' ;;
    esac

    if [ -s "$MEMBER_DIR/in" ]; then
      first_step="Read $MEMBER_DIR/in and begin."
    else
      first_step="The thinker will write $MEMBER_DIR/in shortly; wait for it."
    fi

    role_upper=$(printf '%s' "$ROLE" | tr '[:lower:]' '[:upper:]')
    brief="${SKILL_PREFIX}paired-review-loop You are the $role_upper named '$NAME'. Session dir: $SESSION. Your inbox is $MEMBER_DIR/in and you report in $MEMBER_DIR/out. Your pane is $PANE and the thinker's pane is $THINKER_PANE. $first_step"

    # 2 means sent but unconfirmable — a mid-turn or very narrow pane — which is
    # still sent. Only 1 is a real failure.
    prl_send_verified "$PANE" "$brief"
    send_status=$?
    if [ "$send_status" -eq 1 ]; then
      echo "roster: '$NAME' did not accept the briefing; look at pane $PANE" >&2
      exit 13
    fi
    if [ "$send_status" -eq 2 ]; then
      echo "roster: briefed '$NAME' but could not confirm it (${PRL_UNVERIFIED_REASON:-unverified})" >&2
    fi
    # Submitted is not the same as acted upon; press Enter again while the pane
    # shows no sign of working. Only warn if it never stirs — a quick agent can
    # answer inside the sample, and not every program visibly works.
    prl_wait_until_working "$PANE" ||
      echo "roster: '$NAME' took the briefing but showed no sign of working; check pane $PANE" >&2
    echo "BRIEFED $NAME $PANE"
    ;;

  kick)
    SESSION="${2:?usage: roster.sh kick <session-dir> <name>}"
    NAME="${3:?missing <name>}"
    SESSION=$(cd "$SESSION" && pwd)
    PANE=$("$SCRIPT_DIR/roster.sh" resolve "$SESSION" "$NAME") || exit $?

    if prl_pane_is_shell "$PANE"; then
      echo "roster: '$NAME' is at a shell prompt in $PANE - its agent has exited." >&2
      echo "roster: a human has to start one there again; nothing can be kicked." >&2
      exit 12
    fi

    # Already working: leave it alone. Interrupting a member mid-task to ask
    # whether it is working is how you lose the work it was doing.
    if prl_pane_is_busy "$PANE"; then
      echo "ACTIVE $NAME $PANE (already working)"
      exit 0
    fi

    # A codex goal parks itself when it runs out of authorised work and will not
    # look at its inbox again until it is resumed. Its own footer says so, so
    # read that rather than guessing which agent this is.
    if prl_capture "$PANE" | grep -q 'Goal stalled'; then
      WAKE='/goal resume'
    else
      WAKE="prl: your inbox was updated - read $SESSION/members/$NAME/in and continue"
    fi

    prl_send_verified "$PANE" "$WAKE"
    send_status=$?
    if [ "$send_status" -eq 1 ]; then
      echo "roster: '$NAME' would not accept '$WAKE' in $PANE" >&2
      exit 13
    fi

    # The whole point of this verb. A send-keys that exits 0 proves nothing: the
    # Enter is routinely swallowed, leaving the command sitting visibly unsent
    # while the pane stays parked. A night was lost to a goal that was typed and
    # never submitted, so keep pressing until the pane is actually working.
    if ! prl_wait_until_working "$PANE"; then
      echo "roster: sent '$WAKE' to $PANE but '$NAME' never started working." >&2
      echo "roster: look at the pane - the command is probably still sitting in its" >&2
      echo "roster: input box unsent. Do NOT report this member as running." >&2
      exit 13
    fi
    echo "STARTED $NAME $PANE (sent '$WAKE'; pane is working)"
    ;;

  sync)
    SESSION="${2:?usage: roster.sh sync <session-dir>}"
    SESSION=$(cd "$SESSION" && pwd)
    ROSTER=$(roster_path "$SESSION")
    rewritten="$ROSTER.tmp.$$"
    printf '%s\n' "$ROSTER_HEADER" > "$rewritten"
    found=0
    while IFS=$'\t' read -r pane member role agent member_cwd; do
      [ -z "$member" ] && continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$member" "$role" "$agent" "$pane" "$member_cwd" >> "$rewritten"
      mkdir -p "$SESSION/members/$member/evidence"
      found=$((found + 1))
    done < <(prl_list_tagged_panes "$SESSION")
    mv "$rewritten" "$ROSTER"
    echo "roster: rebuilt $ROSTER from $found live pane(s)"
    ;;

  verify)
    SESSION="${2:?usage: roster.sh verify <session-dir>}"
    SESSION=$(cd "$SESSION" && pwd)
    ROSTER=$(require_roster "$SESSION")
    problems=0
    declare -a names=()
    declare -A member_state=() member_detail=() member_pane=() first_screen=()

    # First pass: settle the states that need no sampling, and photograph the
    # panes that are still in play.
    while IFS=$'\t' read -r name role agent pane member_cwd; do
      case "$name" in '#'* | '') continue ;; esac
      names+=("$name")
      member_pane[$name]="$pane"
      if ! prl_pane_exists "$pane"; then
        member_state[$name]=GONE
        member_detail[$name]="pane $pane no longer exists"
        continue
      fi
      actual=$(prl_pane_tag "$pane" prl_member)
      if [ "$actual" != "$name" ]; then
        member_state[$name]=MISMATCH
        member_detail[$name]="pane $pane is now '${actual:-untagged}'"
        continue
      fi
      if prl_pane_is_shell "$pane"; then
        member_state[$name]=EXITED
        member_detail[$name]="pane $pane is back at a shell prompt"
        continue
      fi
      # The roster records what you asked to spawn; the pane knows what is
      # actually running. A thinker called its worker "codex" for most of a
      # session while the pane had been running Claude all along — and how much
      # you trust a member, and how you weigh its pushback, depends on knowing
      # which it is.
      running=$(prl_pane_command "$pane")
      expected=$(basename "${agent%% *}")
      if [ -n "$running" ] && [ "$running" != "$expected" ]; then
        member_state[$name]=AGENT
        member_detail[$name]="roster says '$expected', pane $pane is running '$running'"
        continue
      fi

      member_state[$name]=LIVE
      member_detail[$name]="$role	$pane	$agent"
      first_screen[$name]=$(prl_capture "$pane")
    done < "$ROSTER"

    # A working agent redraws — the elapsed-time counter in its status line
    # ticks every second — while one sitting on an approval prompt is frozen.
    # That is the only thing separating "still thinking" from "waiting for a
    # human", and the two look identical without it.
    #
    # One sleep covers the whole team: everyone was photographed before it and
    # is compared after, so verifying six members costs the same as one.
    if [ "$PRL_VERIFY_SAMPLE" != "0" ]; then
      for name in "${names[@]}"; do
        [ "${member_state[$name]}" = LIVE ] && { sleep "$PRL_VERIFY_SAMPLE"; break; }
      done
    fi

    for name in "${names[@]}"; do
      state="${member_state[$name]}"
      if [ "$state" = LIVE ]; then
        state=OK
        if [ "$PRL_VERIFY_SAMPLE" != "0" ] &&
          [ "$(prl_capture "${member_pane[$name]}")" = "${first_screen[$name]}" ]; then
          # The screen has not moved. That is only a problem if the member owes
          # a reply: a member that has already answered its current task is
          # supposed to sit still.
          inbox="$SESSION/members/$name/in"
          outbox="$SESSION/members/$name/out"
          if [ -s "$inbox" ] && { [ ! -s "$outbox" ] || [ "$inbox" -nt "$outbox" ]; }; then
            state=WAITING
            member_detail[$name]="pane ${member_pane[$name]} is frozen with its task unanswered - probably stopped on an approval prompt"
          fi
        fi
      fi

      case "$state" in
        OK) echo "OK        $name	${member_detail[$name]}" ;;
        *)
          printf '%-9s %s (%s)\n' "$state" "$name" "${member_detail[$name]}"
          problems=$((problems + 1))
          ;;
      esac
    done

    while IFS=$'\t' read -r pane member role agent member_cwd; do
      [ -z "$member" ] && continue
      if [ -z "$(roster_row "$ROSTER" "$member")" ]; then
        echo "UNLISTED  $member (pane $pane is tagged for this session but not in the roster)"
        problems=$((problems + 1))
      fi
    done < <(prl_list_tagged_panes "$SESSION")

    [ "$problems" -gt 0 ] && exit 1
    exit 0
    ;;

  -h | --help | help)
    usage 0
    ;;

  *)
    echo "roster: unknown verb '$VERB'" >&2
    usage 2
    ;;
esac
