#!/bin/zsh
set -e

cd "$(dirname "$0")/.."

CONFIG_DIR="$HOME/.codex"
CONFIG_FILE="$CONFIG_DIR/config.toml"
HOOKS_FILE="examples/codex-hooks.example.toml"
TMP_FILE="$(mktemp)"

mkdir -p "$CONFIG_DIR"
touch "$CONFIG_FILE"

awk '
  /^# BEGIN CodexStatusLight hooks$/ { skip = 1; next }
  /^# END CodexStatusLight hooks$/ { skip = 0; next }
  skip != 1 { print }
' "$CONFIG_FILE" > "$TMP_FILE"

{
  cat "$TMP_FILE"
  printf "\n# BEGIN CodexStatusLight hooks\n"
  cat "$HOOKS_FILE"
  printf "# END CodexStatusLight hooks\n"
} > "$CONFIG_FILE"

rm -f "$TMP_FILE"

echo "Codex hooks installed in $CONFIG_FILE"
echo "Open Codex and run /hooks once to review and trust them."
