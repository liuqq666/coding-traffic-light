#!/bin/zsh
set -e

cd "$(dirname "$0")/.."
mkdir -p build
cp Sources/CodexStatusLight.swift build/CodexStatusLight.generated.swift
swiftc -framework Cocoa build/CodexStatusLight.generated.swift -o build/CodexStatusLight
echo "Built build/CodexStatusLight"
