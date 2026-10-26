#!/bin/zsh
# 纯感知内核单测：不依赖 Xcode test target，直接编译 BoardGeometry/BoardStabilizer。
# 用法：scripts/run-swift-tests.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ttj-swift-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc \
  "$ROOT/TianTianJunQi/Perception/BoardGeometry.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardSnapshotExporter.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardStabilizer.swift" \
  "$ROOT/TianTianJunQi/Perception/PieceCatalog.swift" \
  "$ROOT/TianTianJunQi/Perception/SnapshotLibrary.swift" \
  "$ROOT/TianTianJunQi/Storage/StorageKit.swift" \
  "$ROOT/Tests/SwiftPerception/main.swift" \
  -o "$BUILD_DIR/perception-tests"

"$BUILD_DIR/perception-tests"
