#!/bin/zsh
set -e

LABEL="com.liuqq666.codex-status-light"
UID_VALUE="$(id -u)"
SUPPORT_DIR="$HOME/Library/Application Support/CodexStatusLight"
APP="$SUPPORT_DIR/CodexStatusLight"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LIGHT="$HOME/.codex/bin/codex-light"

if [ ! -x "$APP" ]; then
  echo "Codex Status Light is not installed. Run ./install.command first."
  exit 1
fi

is_running() {
  pgrep -x "CodexStatusLight" >/dev/null 2>&1
}

if ! is_running; then
  if [ -f "$PLIST" ]; then
    launchctl kickstart -k "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
  fi
  sleep 0.2
fi

if ! is_running; then
  "$APP" >/dev/null 2>&1 &
  sleep 0.2
fi

if [ -x "$LIGHT" ]; then
  "$LIGHT" show >/dev/null 2>&1 || true
fi

echo "Codex Status Light started."
