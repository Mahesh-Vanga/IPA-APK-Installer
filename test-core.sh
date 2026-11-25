#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mobile-installer-tests.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -module-cache-path "$WORK/modules" -swift-version 5 -parse-as-library "$ROOT/Sources/Engine.swift" "$ROOT/Tests/EngineTests.swift" -o "$WORK/EngineTests"
"$WORK/EngineTests"
swiftc -module-cache-path "$WORK/modules" -swift-version 5 -parse-as-library \
  "$ROOT/Sources/DiagnosticTail.swift" "$ROOT/Sources/PanelCloseDelay.swift" \
  "$ROOT/Sources/StatusTapSequence.swift" "$ROOT/Sources/IdleHandoff.swift" \
  "$ROOT/Tests/BackgroundTests.swift" -o "$WORK/BackgroundTests"
"$WORK/BackgroundTests"
