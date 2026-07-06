#!/bin/zsh
set -e

cd "$(dirname "$0")"

APP="$HOME/Library/Application Support/CodexStatusLight/CodexStatusLight"

if [ ! -x "$APP" ]; then
  echo "Codex Status Light is not installed yet. Installing first..."
  ./install.command
else
  ./scripts/start.command
fi
