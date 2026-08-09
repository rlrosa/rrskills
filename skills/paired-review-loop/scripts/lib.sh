#!/usr/bin/env bash
# Shared tmux helpers for the paired-review-loop scripts. Source this file; it
# defines functions only and runs nothing on its own.
#
# Every helper addresses panes by tmux pane ID (%0, %174, ...). Pane IDs are
# unique across the whole tmux server and never reused, so one pane can reach
# any other pane in any session or window without knowing where it lives.

# Seconds to wait between typing a line and pressing Enter. Agent TUIs redraw
# their input box after each keystroke burst; sending Enter too early can land
# before the text is in the box.
PRL_SEND_DELAY="${PRL_SEND_DELAY:-0.3}"

# Seconds to wait after Enter before checking whether the pane reacted.
PRL_REACT_DELAY="${PRL_REACT_DELAY:-1}"

# Foreground commands that mean "no agent is running here, just a shell".
PRL_SHELLS="bash zsh sh fish dash ksh tcsh csh"

# True when tmux is installed and a server is actually reachable. Both matter:
# the binary alone is useless if no server is running to hold the target pane.
prl_tmux_available() {
  command -v tmux > /dev/null 2>&1 || return 1
  tmux list-panes -a -F '#{pane_id}' > /dev/null 2>&1
}

# True when the given pane ID currently exists.
#
# Do not substitute `tmux display-message -t <pane>` for this: it prints an
# empty line and exits 0 for a pane that does not exist, so it cannot tell
# "gone" from "alive but blank".
prl_pane_exists() {
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$1"
}

# Print the command currently in the foreground of the given pane.
prl_pane_command() {
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# True when the pane is sitting at a shell prompt, which means whatever agent
# was running there has exited. Typing into such a pane would run the text as a
# shell command, so callers must check this before sending anything.
prl_pane_is_shell() {
  local foreground_command
  foreground_command=$(prl_pane_command "$1")
  [ -z "$foreground_command" ] && return 0
  case " $PRL_SHELLS " in
    *" $foreground_command "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print the pane's visible contents, used to tell whether it reacted to input.
prl_capture() {
  tmux capture-pane -p -t "$1" 2>/dev/null
}

# Print a pane's cursor position as "column,row".
#
# This is the one honest answer to "is there anything in the input box". Agent
# TUIs display greyed-out placeholder suggestions there — codex offers "Write
# tests for @filename" — and reading the screen cannot tell that apart from a
# message somebody typed. The cursor can: a placeholder leaves it parked at the
# start of the box, real characters push it along.
prl_cursor() {
  tmux display-message -p -t "$1" '#{cursor_x},#{cursor_y}' 2>/dev/null
}

# Stamp a pane with the session it serves and the member it is running, so the
# pane itself carries its identity.
#
# This is the half of the index that cannot go stale: roster.tsv says which pane
# a member should be in, the pane says which member it actually is, and a send
# only goes ahead when the two agree. It also means a lost roster can be rebuilt
# by scanning panes rather than guessing.
# The agent command is tagged too, not just the name and role, so a roster
# rebuilt from panes comes back complete rather than approximate:
# pane_current_command would only report `claude`, losing the model and flags.
prl_tag_pane() {
  local pane="$1" session="$2" member="$3" role="$4" agent_command="$5"
  tmux set-option -p -t "$pane" @prl_session "$session" 2>/dev/null || return 1
  tmux set-option -p -t "$pane" @prl_member "$member" 2>/dev/null || return 1
  tmux set-option -p -t "$pane" @prl_role "$role" 2>/dev/null || return 1
  tmux set-option -p -t "$pane" @prl_cmd "$agent_command" 2>/dev/null || return 1
}

# Print a pane's tag value, or nothing when the pane is untagged or gone.
prl_pane_tag() {
  tmux display-message -p -t "$1" "#{@$2}" 2>/dev/null
}

# List every tagged pane belonging to a session, as `pane<TAB>member<TAB>role`.
#
# Reads the whole server rather than one window: members can be moved between
# windows and sessions by hand, and their pane IDs follow them.
prl_list_tagged_panes() {
  local session="$1"
  tmux list-panes -a \
    -F '#{pane_id}	#{@prl_session}	#{@prl_member}	#{@prl_role}	#{@prl_cmd}	#{pane_current_path}' \
    2>/dev/null \
    | awk -F'\t' -v session="$session" \
      '$2 == session && $3 != "" { print $1 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }'
}

# Type one line into a pane and submit it, without checking it arrived. Use it
# for panes running a shell, which buffers whatever is typed at it and runs the
# line once it starts reading. Agent TUIs drop early input instead, so send to
# those with prl_send_verified.
#
# The text and the Enter go in separate calls, and the text is sent with -l so
# tmux treats it as literal characters. Otherwise a message containing a word
# like "Enter" or "C-c" would be interpreted as a key name, and a leading dash
# would be parsed as an option.
prl_send_line() {
  local pane="$1" text="$2"
  tmux send-keys -t "$pane" -l -- "$text" || return 1
  sleep "$PRL_SEND_DELAY"
  tmux send-keys -t "$pane" Enter
}

# Seconds to watch a pane to decide whether it is mid-turn.
PRL_BUSY_SAMPLE="${PRL_BUSY_SAMPLE:-1.2}"

# Below this width an agent TUI has no room to lay out an input box, so nothing
# typed into it can be confirmed and the pane should not be created that narrow
# in the first place. Observed live: a thinker's pane squeezed to 1 column by
# repeated splits stayed perfectly alive, and every nudge to it failed.
PRL_MIN_PANE_WIDTH="${PRL_MIN_PANE_WIDTH:-40}"

# Print a pane's width in columns, or 0 if it has gone.
prl_pane_width() {
  tmux display-message -p -t "$1" '#{pane_width}' 2>/dev/null || echo 0
}

# True when the pane is redrawing, which for an agent TUI means it is working.
# A working agent ticks an elapsed-time counter every second; an idle one is
# perfectly still.
prl_pane_is_busy() {
  local pane="$1" first second
  first=$(prl_capture "$pane")
  sleep "$PRL_BUSY_SAMPLE"
  second=$(prl_capture "$pane")
  [ "$first" != "$second" ]
}

# Block until a pane stops redrawing, meaning a program that just started has
# finished painting its first screen. Always returns 0; a pane that never
# settles is left for the caller's own checks to deal with.
#
# Only worth calling on a cold start. A working agent animates a spinner, so it
# never looks settled and this would just burn the timeout.
prl_wait_ready() {
  local pane="$1" timeout_s="${2:-30}" previous_screen="" current_screen second
  for ((second = 0; second < timeout_s; second++)); do
    current_screen=$(prl_capture "$pane")
    [ -n "$previous_screen" ] && [ "$current_screen" = "$previous_screen" ] && return 0
    previous_screen="$current_screen"
    sleep 1
  done
  return 0
}

# Type a line into a pane and submit it, checking both halves actually took
# effect. Returns 1 if the text or the Enter never got through.
#
# Both halves need checking, and they fail for different reasons.
#
# The text can vanish: a TUI that is still starting up has not begun reading its
# input, so what you type sits in the terminal buffer unread.
#
# The Enter can vanish on its own, and this is the failure that looks like
# success — the characters are echoed to the screen, so the message appears
# delivered, but the Enter is discarded and the message sits in the input box
# forever. "Typed" is not "sent", so both are checked separately.
#
# Each check reads the cursor first and the screen only as a fallback. The
# cursor is the more trustworthy of the two: it moves only for real characters,
# and it returns to the start of the box when a message is actually submitted.
# Returns 0 when the send was confirmed, 2 when it was sent but could not be
# confirmed, and 1 when it definitely did not get through.
prl_send_verified() {
  local pane="$1" text="$2" attempts="${3:-20}"
  local probe count_before count_after attempt enter_press
  local cursor_before cursor_typed screen_before_enter

  # Two states make confirmation impossible, and in both of them retrying does
  # active harm: the C-u that clears a half-typed message erases a perfectly
  # good queued one instead. Observed live, a nudge to a busy thinker was
  # retried twenty times and destroyed rather than delivered.
  #
  # So when the pane cannot answer for itself, send once, say plainly that it is
  # unconfirmed, and let the recipient's own wait deadline be the backstop.
  # That is what deadlines are for.
  local width
  width=$(prl_pane_width "$pane")
  PRL_UNVERIFIED_REASON=""
  if [ "$width" -lt "$PRL_MIN_PANE_WIDTH" ]; then
    # Too narrow to lay out an input box, so neither the cursor nor the text
    # can show the message arriving.
    PRL_UNVERIFIED_REASON="pane is only $width columns wide"
  elif prl_pane_is_busy "$pane"; then
    # A working TUI stops redrawing its input box and parks the cursor
    # elsewhere, so every check below would report "nothing arrived".
    PRL_UNVERIFIED_REASON="pane is mid-turn"
  fi
  if [ -n "$PRL_UNVERIFIED_REASON" ]; then
    tmux send-keys -t "$pane" -l -- "$text" || return 1
    sleep "$PRL_SEND_DELAY"
    tmux send-keys -t "$pane" Enter || return 1
    return 2
  fi

  # Compare a short leading slice rather than the whole message. The TUI wraps a
  # long line across rows, so the full string never appears verbatim on screen.
  probe=${text:0:20}
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    cursor_before=$(prl_cursor "$pane")
    count_before=$(prl_capture "$pane" | grep -cF -- "$probe")
    tmux send-keys -t "$pane" -l -- "$text" || return 1
    sleep "$PRL_SEND_DELAY"
    cursor_typed=$(prl_cursor "$pane")
    count_after=$(prl_capture "$pane" | grep -cF -- "$probe")

    # Count occurrences rather than just looking for the text: an earlier
    # round's nudge may still be on screen, and that must not read as this one
    # arriving. The cursor having moved settles it either way.
    if [ "$cursor_typed" != "$cursor_before" ] || [ "$count_after" -gt "$count_before" ]; then
      # Press Enter until the message is gone from the input box. A stray Enter
      # on an empty box does nothing in these TUIs, so retrying is safe.
      for ((enter_press = 1; enter_press <= 5; enter_press++)); do
        screen_before_enter=$(prl_capture "$pane")
        tmux send-keys -t "$pane" Enter
        sleep 1
        # The cursor snapping back from where the typing left it means the box
        # emptied, which is what submitted actually looks like.
        [ "$(prl_cursor "$pane")" != "$cursor_typed" ] && return 0
        [ "$(prl_capture "$pane")" != "$screen_before_enter" ] && return 0
      done
      return 1
    fi

    # Nothing arrived at all. Clear anything that half-landed so a retry cannot
    # end up typing the message twice into the same input box.
    tmux send-keys -t "$pane" C-u
    sleep 1
  done
  return 1
}

# Write KEY='value' into a session.env, replacing any existing line for that
# key so re-registering a pane never leaves two conflicting values behind.
prl_set_key() {
  local env_file="$1" key="$2" value="$3" rewritten
  rewritten="$env_file.tmp.$$"
  # Escape single quotes so values with spaces or quotes survive being sourced.
  value=${value//\'/\'\\\'\'}
  grep -v "^$key=" "$env_file" > "$rewritten" 2>/dev/null || : > "$rewritten"
  printf "%s='%s'\n" "$key" "$value" >> "$rewritten"
  mv "$rewritten" "$env_file"
}
