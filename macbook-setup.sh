#!/usr/bin/env bash
# macbook-setup.sh — one-shot setup for the MacBook (or any second workstation)
# to match the mac-mini's ship-epic / claude-memory configuration.
#
# Idempotent — safe to re-run. Each step checks current state before acting.
#
# What it does:
#   1. Pulls claude-memory at ~/.claude/projects (if cloned; otherwise tells you)
#   2. Clones velo9-ai/ship-epic at ~/Developer/velo9-dev/ship-epic (if missing)
#   3. Creates the user-level symlinks (~/.claude/docs/ + ~/.claude/commands/)
#   4. Adds the SessionStart hook to ~/.claude/settings.json (merging — preserves existing)
#   5. Creates ~/.claude/logs/ for the hook's log file
#   6. Optionally appends a `claude-sync` shell alias (asks first)
#
# Usage:
#   bash macbook-setup.sh
#
# Requirements (must already be installed):
#   - git, jq, ssh (with SSH key registered with GitHub for velo9-ai)
#
# After running, restart Claude Code or run /hooks once so it picks up the hook.

set -euo pipefail

# ── Paths (assumed identical to mac-mini layout per memory/dev_workstations) ──
CLAUDE_DIR="$HOME/.claude"
CLAUDE_PROJECTS="$CLAUDE_DIR/projects"
DEV_ROOT="$HOME/Developer/velo9-dev"
SHIP_EPIC="$DEV_ROOT/ship-epic"
SETTINGS="$CLAUDE_DIR/settings.json"
LOGS_DIR="$CLAUDE_DIR/logs"

# ── Pretty printing ──────────────────────────────────────────────────────────
_step() { echo ""; echo "── $* ──"; }
_ok()   { echo "  ✓ $*"; }
_skip() { echo "  ↷ $*"; }
_warn() { echo "  ⚠ $*"; }
_fail() { echo "  ✗ $*"; exit 1; }

# ── Prereq check ─────────────────────────────────────────────────────────────
_step "Checking prereqs"
for bin in git jq ssh; do
  command -v "$bin" &>/dev/null && _ok "$bin found" || _fail "$bin not on PATH"
done

if ! ssh -T git@github.com 2>&1 | grep -qE "(successfully authenticated|Permission denied)"; then
  _warn "SSH to github.com didn't authenticate. If this is a fresh machine, add your SSH key to GitHub first."
fi

# ── Step 1: pull claude-memory ───────────────────────────────────────────────
_step "claude-memory at $CLAUDE_PROJECTS"
if [[ -d "$CLAUDE_PROJECTS/.git" ]]; then
  _ok "already cloned"
  echo "  pulling..."
  (cd "$CLAUDE_PROJECTS" && git pull origin main 2>&1 | sed 's/^/    /')
else
  _warn "$CLAUDE_PROJECTS is not a git checkout."
  echo "  If you've never set this up, run:"
  echo "    cd ~/.claude && git clone git@github.com:velo9-ai/claude-memory.git projects"
  echo "  (or however you've set up your memory sync)."
  echo "  Then re-run this script."
  exit 1
fi

# ── Step 2: clone ship-epic if missing ───────────────────────────────────────
_step "ship-epic at $SHIP_EPIC"
mkdir -p "$DEV_ROOT"
if [[ -d "$SHIP_EPIC/.git" ]]; then
  _ok "already cloned"
  echo "  pulling..."
  (cd "$SHIP_EPIC" && git pull origin main 2>&1 | sed 's/^/    /')
else
  echo "  cloning..."
  git clone https://github.com/velo9-ai/ship-epic.git "$SHIP_EPIC" 2>&1 | sed 's/^/    /'
  _ok "cloned"
fi

# ── Step 3: user-level symlinks ──────────────────────────────────────────────
_step "User-level symlinks under $CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR/docs" "$CLAUDE_DIR/commands"

# docs/ship-epic-inner-gate.md  →  ../projects/_shared/docs/ship-epic-inner-gate.md
if [[ -L "$CLAUDE_DIR/docs/ship-epic-inner-gate.md" ]]; then
  _ok "docs/ship-epic-inner-gate.md symlink already in place"
else
  if [[ -e "$CLAUDE_DIR/docs/ship-epic-inner-gate.md" ]]; then
    _warn "docs/ship-epic-inner-gate.md exists as a regular file — moving to .bak"
    mv "$CLAUDE_DIR/docs/ship-epic-inner-gate.md" "$CLAUDE_DIR/docs/ship-epic-inner-gate.md.bak"
  fi
  ln -sf ../projects/_shared/docs/ship-epic-inner-gate.md "$CLAUDE_DIR/docs/ship-epic-inner-gate.md"
  _ok "docs/ship-epic-inner-gate.md symlinked"
fi

# commands/bmad-ship-story.md  →  ../projects/_shared/commands/bmad-ship-story.md
if [[ -L "$CLAUDE_DIR/commands/bmad-ship-story.md" ]]; then
  _ok "commands/bmad-ship-story.md symlink already in place"
else
  if [[ -e "$CLAUDE_DIR/commands/bmad-ship-story.md" ]]; then
    _warn "commands/bmad-ship-story.md exists as a regular file — moving to .bak"
    mv "$CLAUDE_DIR/commands/bmad-ship-story.md" "$CLAUDE_DIR/commands/bmad-ship-story.md.bak"
  fi
  ln -sf ../projects/_shared/commands/bmad-ship-story.md "$CLAUDE_DIR/commands/bmad-ship-story.md"
  _ok "commands/bmad-ship-story.md symlinked"
fi

# Resolution chain check
for p in "$CLAUDE_DIR/docs/ship-epic-inner-gate.md" "$CLAUDE_DIR/commands/bmad-ship-story.md"; do
  if [[ -r "$p" ]] && head -c 1 "$p" >/dev/null 2>&1; then
    _ok "$(basename "$p") resolves cleanly"
  else
    _fail "$(basename "$p") symlink is dangling — investigate"
  fi
done

# ── Step 4: SessionStart hook in settings.json ───────────────────────────────
_step "SessionStart hook in $SETTINGS"
mkdir -p "$LOGS_DIR"

HOOK_CMD='mkdir -p ~/.claude/logs && ~/.claude/projects/_shared/bin/sync.sh start >> ~/.claude/logs/sync.log 2>&1 || true'

if [[ -f "$SETTINGS" ]]; then
  # Check if hook is already installed
  EXISTING="$(jq -r '.hooks.SessionStart[]? | .hooks[]? | select(.command == "'"$HOOK_CMD"'") | .command' "$SETTINGS" 2>/dev/null || true)"
  if [[ -n "$EXISTING" ]]; then
    _ok "SessionStart hook already installed"
  else
    # Merge the hook into existing settings.json
    cp "$SETTINGS" "${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
    jq --arg cmd "$HOOK_CMD" '
      .hooks = (.hooks // {}) |
      .hooks.SessionStart = (.hooks.SessionStart // []) |
      .hooks.SessionStart += [{
        "hooks": [{
          "type": "command",
          "command": $cmd,
          "async": true,
          "timeout": 60
        }]
      }]
    ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    _ok "SessionStart hook merged into settings.json (backup at .bak.<timestamp>)"
  fi
else
  cat > "$SETTINGS" <<JSONEOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_CMD",
            "async": true,
            "timeout": 60
          }
        ]
      }
    ]
  }
}
JSONEOF
  _ok "settings.json created with SessionStart hook"
fi

# Validate
if jq . "$SETTINGS" >/dev/null 2>&1; then
  _ok "settings.json is valid JSON"
else
  _fail "settings.json is invalid JSON after edit — restore from the .bak.* backup"
fi

# ── Step 5: shell alias (optional) ───────────────────────────────────────────
_step "Optional shell alias for sync.sh"
SHELL_RC=""
if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$SHELL" == *zsh* ]]; then
  SHELL_RC="$HOME/.zshrc"
elif [[ -n "${BASH_VERSION:-}" ]] || [[ "$SHELL" == *bash* ]]; then
  SHELL_RC="$HOME/.bashrc"
fi

if [[ -n "$SHELL_RC" ]] && [[ -f "$SHELL_RC" ]]; then
  if grep -q "alias claude-sync=" "$SHELL_RC" 2>/dev/null; then
    _ok "claude-sync alias already in $SHELL_RC"
  else
    echo "  Add 'alias claude-sync=...' to $SHELL_RC? (y/N)"
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      echo "alias claude-sync='~/.claude/projects/_shared/bin/sync.sh'" >> "$SHELL_RC"
      _ok "alias added — open a new shell or 'source $SHELL_RC' to use"
    else
      _skip "skipped — add manually if desired:"
      echo "    echo \"alias claude-sync='~/.claude/projects/_shared/bin/sync.sh'\" >> $SHELL_RC"
    fi
  fi
else
  _skip "no shell rc found ($SHELL); add alias manually"
fi

# ── Step 6: verify the sync script works now ─────────────────────────────────
_step "Smoke test"
if "$CLAUDE_PROJECTS/_shared/bin/sync.sh" status; then
  _ok "sync.sh status runs cleanly"
else
  _fail "sync.sh status failed — investigate before relying on the hook"
fi

# ── Final summary ────────────────────────────────────────────────────────────
_step "Setup complete"
echo "Next steps:"
echo "  1. Restart Claude Code OR run /hooks once in any session so the new SessionStart hook is registered."
echo "  2. From now on, every new Claude Code session will auto-pull both repos at start."
echo "  3. At session end, run \`claude-sync end \"message\"\` manually (or just \`~/.claude/projects/_shared/bin/sync.sh end\`)."
echo ""
echo "Files installed:"
echo "  ~/.claude/docs/ship-epic-inner-gate.md           → symlink"
echo "  ~/.claude/commands/bmad-ship-story.md            → symlink"
echo "  ~/.claude/settings.json                          → SessionStart hook added (backup .bak.* if changed)"
echo "  ~/.claude/logs/sync.log                          → hook output goes here"
echo "  ~/Developer/velo9-dev/ship-epic/                 → public repo clone"
echo ""
echo "Inspect log after first auto-fire:"
echo "  tail -20 ~/.claude/logs/sync.log"
