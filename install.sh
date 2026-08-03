#!/usr/bin/env bash
set -e

# Base target directories (can be overridden via environment variables for testing)
CLAUDE_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
AGY_DIR="${AGY_SKILLS_DIR:-$HOME/.gemini/config/skills}"
CODEX_DIR="${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SRC_DIR="$REPO_ROOT/skills"

TARGET="all"
MODE="symlink"
SKILL_NAME="all"
UNINSTALL=false
LIST=false

usage() {
  cat << EOF
Usage: ./install.sh [options]

Options:
  -t, --target <tool>    Target assistant: claude, agy, codex, all (default: all)
  -m, --mode <mode>      Installation mode: symlink, copy (default: symlink)
  -s, --skill <name>     Skill to install/uninstall (default: all)
  -u, --uninstall        Uninstall skill(s) from specified target(s)
  -l, --list             List available skills and installation status
  -h, --help             Show this help message

Examples:
  ./install.sh                           # Symlink all skills to claude, agy, codex
  ./install.sh -t claude                 # Install all skills for Claude only
  ./install.sh -s paired-review-loop     # Install specific skill
  ./install.sh -m copy                   # Copy skills instead of symlinking
  ./install.sh -u                        # Uninstall skills from all targets
  ./install.sh -l                        # View status of installed skills
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      TARGET="$2"
      shift 2
      ;;
    -m|--mode)
      MODE="$2"
      shift 2
      ;;
    -s|--skill)
      SKILL_NAME="$2"
      shift 2
      ;;
    -u|--uninstall)
      UNINSTALL=true
      shift
      ;;
    -l|--list)
      LIST=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

get_target_dirs() {
  case "$TARGET" in
    claude) echo "$CLAUDE_DIR" ;;
    agy) echo "$AGY_DIR" ;;
    codex) echo "$CODEX_DIR" ;;
    all) echo "$CLAUDE_DIR $AGY_DIR $CODEX_DIR" ;;
    *)
      echo "Error: Invalid target '$TARGET'. Must be claude, agy, codex, or all." >&2
      exit 1
      ;;
  esac
}

get_target_label() {
  local dir="$1"
  case "$dir" in
    "$CLAUDE_DIR") echo "Claude" ;;
    "$AGY_DIR") echo "AGY (Antigravity)" ;;
    "$CODEX_DIR") echo "Codex" ;;
    *) echo "$dir" ;;
  esac
}

get_skills_list() {
  if [ "$SKILL_NAME" != "all" ]; then
    if [ ! -d "$SKILLS_SRC_DIR/$SKILL_NAME" ]; then
      echo "Error: Skill '$SKILL_NAME' not found in $SKILLS_SRC_DIR." >&2
      exit 1
    fi
    echo "$SKILL_NAME"
  else
    if [ ! -d "$SKILLS_SRC_DIR" ]; then
      echo "Error: Skills directory $SKILLS_SRC_DIR does not exist." >&2
      exit 1
    fi
    find "$SKILLS_SRC_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;
  fi
}

do_list() {
  echo "Available skills in repository:"
  skills=$(get_skills_list)
  if [ -z "$skills" ]; then
    echo "  (None found)"
    return
  fi

  for s in $skills; do
    echo "• $s:"
    for dest in $CLAUDE_DIR $AGY_DIR $CODEX_DIR; do
      label=$(get_target_label "$dest")
      target_path="$dest/$s"
      if [ -L "$target_path" ]; then
        sym_link=$(readlink "$target_path")
        echo "   - [$label]: Installed (Symlink -> $sym_link)"
      elif [ -d "$target_path" ]; then
        echo "   - [$label]: Installed (Directory Copy)"
      else
        echo "   - [$label]: Not installed"
      fi
    done
  done
}

if [ "$LIST" = true ]; then
  do_list
  exit 0
fi

if [ "$MODE" != "symlink" ] && [ "$MODE" != "copy" ]; then
  echo "Error: Invalid mode '$MODE'. Must be 'symlink' or 'copy'." >&2
  exit 1
fi

TARGET_DIRS=$(get_target_dirs)
SKILLS=$(get_skills_list)

if [ "$UNINSTALL" = true ]; then
  for s in $SKILLS; do
    for dest in $TARGET_DIRS; do
      label=$(get_target_label "$dest")
      target_path="$dest/$s"
      if [ -L "$target_path" ] || [ -d "$target_path" ]; then
        rm -rf "$target_path"
        echo "Uninstalled '$s' from $label ($target_path)"
      else
        echo "Skipping '$s' on $label (not installed)"
      fi
    done
  done
  exit 0
fi

for dest in $TARGET_DIRS; do
  label=$(get_target_label "$dest")
  mkdir -p "$dest"

  for s in $SKILLS; do
    src_path="$SKILLS_SRC_DIR/$s"
    target_path="$dest/$s"

    # Remove existing link/directory if present
    if [ -L "$target_path" ] || [ -d "$target_path" ]; then
      rm -rf "$target_path"
    fi

    if [ "$MODE" = "symlink" ]; then
      ln -s "$src_path" "$target_path"
      echo "Installed '$s' to $label ($target_path) [Symlink]"
    else
      cp -r "$src_path" "$target_path"
      echo "Installed '$s' to $label ($target_path) [Copy]"
    fi
  done
done

echo "Done!"
