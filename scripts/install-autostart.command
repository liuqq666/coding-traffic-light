#!/bin/zsh
set -e

cd "$(dirname "$0")/.."

LABEL="com.liuqq666.codex-status-light"
PLIST_NAME="$LABEL.plist"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
DEST="$LAUNCH_AGENTS/$PLIST_NAME"
UID_VALUE="$(id -u)"
SUPPORT_DIR="$HOME/Library/Application Support/CodexStatusLight"

if [ ! -x "$SUPPORT_DIR/CodexStatusLight" ]; then
  ./scripts/build.command
  mkdir -p "$SUPPORT_DIR"
  cp ./build/CodexStatusLight "$SUPPORT_DIR/CodexStatusLight"
  chmod +x "$SUPPORT_DIR/CodexStatusLight"
fi

mkdir -p "$LAUNCH_AGENTS" "$SUPPORT_DIR"
sed -e "s#__SUPPORT_DIR__#$SUPPORT_DIR#g" scripts/launch-agent.plist.template > "$DEST"
chmod 644 "$DEST"

launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE" "$DEST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_VALUE" "$DEST"
launchctl enable "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true

echo "Autostart installed: $DEST"
