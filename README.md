# rrskills

AI Assistant Skills collection for **Claude Code**, **AGY (Antigravity)**, and **OpenAI Codex**.

## Skills Included

- **`paired-review-loop`**: Two-agent file-based review & verification loop where a thinker (reviewer/orchestrator) drives a worker (implementer) through tasks, verifying all proof before accepting. When both agents run in tmux panes, the thinker can spawn the worker's pane with the agent of your choice (`claude`, `codex`, `agy ...`) and the two wake each other instantly via `tmux send-keys` instead of polling.

## Easy Skill Installer (`install.sh`)

Use `./install.sh` to install or symlink skills from this repository to your AI assistant skill directories:
- **Claude**: `~/.claude/skills`
- **AGY**: `~/.gemini/config/skills`
- **Codex**: `~/.codex/skills`

### Usage

```bash
# Install (symlink) all skills for Claude, AGY, and Codex (Default)
./install.sh

# List available skills & installation status
./install.sh -l

# Install for a specific assistant
./install.sh -t claude
./install.sh -t agy
./install.sh -t codex

# Install in copy mode (independent files instead of symlink)
./install.sh -m copy

# Install a specific skill
./install.sh -s paired-review-loop

# Uninstall skills
./install.sh -u
```

### Why Symlinking?

By default, `./install.sh` creates symbolic links from your AI assistant's skills directories to this git repository. Any updates, fixes, or additions made in this repository immediately take effect across all your AI tools without needing to re-install.

## Tests

```bash
./test/run.sh
```

Runs every `test/*.test.cjs` with plain Node — no dependencies to install. The tmux tests run against their own tmux server on a private socket, so they cannot touch your real sessions, and they skip themselves if `tmux` isn't installed.
