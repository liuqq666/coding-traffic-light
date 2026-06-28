#!/bin/zsh
set -e

cd "$(dirname "$0")/.."
mkdir -p build
swiftc -framework Cocoa Sources/CodexStatusLight.swift -o build/CodexStatusLight
echo "Built build/CodexStatusLight"
