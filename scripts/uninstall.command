#!/bin/zsh
set -e

cd "$(dirname "$0")/.."
./scripts/uninstall-autostart.command || true

rm -f "$HOME/.codex/bin/codex-light"
rm -f "$HOME/.codex/bin/codex-light-run"
rm -f "$HOME/.codex/bin/codex-light-hook"
rm -f "$HOME/Library/Application Support/CodexStatusLight/CodexStatusLight"

echo "Uninstalled Codex Status Light."
