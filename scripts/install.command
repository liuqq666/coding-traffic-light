#!/bin/zsh
set -e

cd "$(dirname "$0")/.."

SUPPORT_DIR="$HOME/Library/Application Support/CodexStatusLight"
BIN_DIR="$HOME/.codex/bin"

./scripts/build.command

mkdir -p "$SUPPORT_DIR" "$BIN_DIR"
cp ./build/CodexStatusLight "$SUPPORT_DIR/CodexStatusLight"
mkdir -p "$SUPPORT_DIR/Assets"
cp ./Assets/traffic-light-real-working.png "$SUPPORT_DIR/Assets/traffic-light-real-working.png"
cp ./Assets/traffic-light-real-done.png "$SUPPORT_DIR/Assets/traffic-light-real-done.png"
cp ./Assets/traffic-light-real-waiting.png "$SUPPORT_DIR/Assets/traffic-light-real-waiting.png"
cp ./Assets/traffic-light-real-idle.png "$SUPPORT_DIR/Assets/traffic-light-real-idle.png"
chmod +x "$SUPPORT_DIR/CodexStatusLight"

ln -sf "$PWD/bin/codex-light" "$BIN_DIR/codex-light"
ln -sf "$PWD/bin/codex-light-run" "$BIN_DIR/codex-light-run"
ln -sf "$PWD/bin/codex-light-hook" "$BIN_DIR/codex-light-hook"
chmod +x "$PWD/bin/codex-light" "$PWD/bin/codex-light-run" "$PWD/bin/codex-light-hook"

./scripts/install-autostart.command
./scripts/install-codex-hooks.command

echo "Installed Codex Status Light."
echo "Binary: $SUPPORT_DIR/CodexStatusLight"
echo "Commands: $BIN_DIR/codex-light, $BIN_DIR/codex-light-run, $BIN_DIR/codex-light-hook"
echo "Next: open Codex and run /hooks once to trust the status-light hooks."
