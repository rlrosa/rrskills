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
# Both halves need checking, and for different reasons. A TUI that is still
# starting up has not begun reading its input, so what you type sits in the
# terminal buffer: the characters are echoed to the screen, which makes the
# message *look* delivered, but the Enter that follows is discarded and the
# message is left parked in the input box forever. Watching for the pane to
# react to the Enter is what separates "typed" from "sent".
prl_send_verified() {
  local pane="$1" text="$2" attempts="${3:-20}"
  local probe count_before count_after screen_before_enter attempt enter_press
  # Compare a short leading slice rather than the whole message. The TUI wraps a
  # long line across rows, so the full string never appears verbatim on screen.
  probe=${text:0:20}
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    count_before=$(prl_capture "$pane" | grep -cF -- "$probe")
    tmux send-keys -t "$pane" -l -- "$text" || return 1
    sleep "$PRL_SEND_DELAY"
    count_after=$(prl_capture "$pane" | grep -cF -- "$probe")
    # Count occurrences rather than just looking for the text: an earlier
    # round's nudge may still be on screen, and that must not read as this one
    # arriving.
    if [ "$count_after" -gt "$count_before" ]; then
      # Press Enter until the pane visibly responds. A stray Enter on an empty
      # input box does nothing in these TUIs, so retrying is safe.
      for ((enter_press = 1; enter_press <= 5; enter_press++)); do
        screen_before_enter=$(prl_capture "$pane")
        tmux send-keys -t "$pane" Enter
        sleep 1
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
