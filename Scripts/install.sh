#!/bin/bash
set -euo pipefail

# LogRoller Installer
# Run from the mounted DMG volume to install the app, CLI, and Claude Code skill.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== LogRoller Installer ==="
echo ""

# Install app
echo "→ Installing LogRoller.app to /Applications..."
if [ -d "$SCRIPT_DIR/LogRoller.app" ]; then
    cp -R "$SCRIPT_DIR/LogRoller.app" /Applications/
    echo "✓ LogRoller.app installed"
else
    echo "❌ LogRoller.app not found in $SCRIPT_DIR"
    exit 1
fi

# Install CLI
echo "→ Installing logroller CLI to ~/bin..."
mkdir -p "$HOME/bin"
cp "$SCRIPT_DIR/logroller" "$HOME/bin/logroller"
chmod +x "$HOME/bin/logroller"
echo "✓ logroller CLI installed"

# Install Claude Code skill
SKILL_DIR="$HOME/.claude/skills/logroller-client-integration"
echo "→ Installing Claude Code skill to $SKILL_DIR..."
mkdir -p "$SKILL_DIR"
cp "$SCRIPT_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"
echo "✓ Claude Code skill installed"

echo ""
echo "=== Installation complete ==="
echo ""
echo "Make sure ~/bin is in your PATH. The logroller CLI and"
echo "Claude Code skill are ready to use."
