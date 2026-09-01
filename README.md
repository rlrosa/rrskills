# rrskills

AI Assistant Skills collection for **Claude Code**, **AGY (Antigravity)**, and **OpenAI Codex**.

Current version: **0.7.0** (see `VERSION`). Released versions are git tags, `v<version>`.

## Skills Included

- **`paired-review-loop`**: File-based review & verification loop where a thinker (reviewer/orchestrator) drives a team — a worker that implements, plus optional testers that run things and capture evidence — verifying all proof before accepting. Members exchange plain files. Under tmux **you** create each member's pane and hand over its ID; the skill cannot create, close or resize panes, and can only reach panes you registered. Each registered pane is tagged with its identity, so a stale roster can never send a task to the wrong agent.

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
