#!/bin/bash
set -euo pipefail

DEST="$HOME/.claude"
SCRIPT="statusline-command.sh"
SETTINGS="$DEST/settings.json"
RAW_URL="https://raw.githubusercontent.com/sk-ilya/claude-statusline/main/$SCRIPT"

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR=""

mkdir -p "$DEST"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$SCRIPT" ]; then
    cp "$SCRIPT_DIR/$SCRIPT" "$DEST/$SCRIPT"
else
    echo "Fetching $SCRIPT from GitHub..."
    curl -fsSL "$RAW_URL" -o "$DEST/$SCRIPT"
fi

chmod +x "$DEST/$SCRIPT"

if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi

tmp=$(mktemp)
jq --arg cmd "$DEST/$SCRIPT" '.statusLine = {"type": "command", "command": $cmd}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "Installed. The statusline will appear in new Claude sessions."
