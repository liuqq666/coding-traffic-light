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
./scripts/start.command

echo "Installed Codex Status Light."
echo "Binary: $SUPPORT_DIR/CodexStatusLight"
echo "Commands: $BIN_DIR/codex-light, $BIN_DIR/codex-light-run, $BIN_DIR/codex-light-hook"
echo "Quick start: double-click start.command or run $BIN_DIR/codex-light show"
echo "Codex startup: hooks will start the light on Codex activity after you trust them once with /hooks."
