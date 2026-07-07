#!/bin/zsh
set -e

cd "$(dirname "$0")/.."
if grep -q "doneAutoIdleInterval" Sources/CodexStatusLight.swift; then
  patch -p0 < scripts/status-rules.patch
fi
mkdir -p build
swiftc -framework Cocoa Sources/CodexStatusLight.swift -o build/CodexStatusLight
echo "Built build/CodexStatusLight"
