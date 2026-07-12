#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG_FILE="$CONFIG_DIR/config.toml"
HOOKS_FILE="$ROOT_DIR/examples/codex-hooks.example.toml"

PYTHON="${CODEX_PYTHON:-}"
if [ -z "$PYTHON" ]; then
  CODEX_BUNDLED_PYTHON="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
  if [ -x "$CODEX_BUNDLED_PYTHON" ]; then
    PYTHON="$CODEX_BUNDLED_PYTHON"
  else
    PYTHON="$(command -v python3 || true)"
  fi
fi

if [ -z "$PYTHON" ] || [ ! -x "$PYTHON" ]; then
  echo "Python 3 is required to install Codex hooks safely." >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR"
"$PYTHON" "$SCRIPT_DIR/install_codex_hooks.py" \
  --config "$CONFIG_FILE" \
  --hooks "$HOOKS_FILE"

echo "Codex hooks installed in $CONFIG_FILE"
echo "Open Codex and run /hooks once to review and trust new or changed hooks."
