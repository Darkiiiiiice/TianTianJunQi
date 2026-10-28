#!/bin/zsh
# 纯感知内核单测：不依赖 Xcode test target，直接编译 BoardGeometry/BoardStabilizer。
# 用法：scripts/run-swift-tests.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ttj-swift-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc \
  "$ROOT/TianTianJunQi/Perception/AutoLabelVote.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardAutoSampleTracker.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardChangeDetector.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardGeometry.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardPieceClassifier.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardSnapshotExporter.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardStabilizer.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardStateBuilder.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardTap.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardTurnReader.swift" \
  "$ROOT/TianTianJunQi/Perception/GameState.swift" \
  "$ROOT/TianTianJunQi/Perception/OCRText.swift" \
  "$ROOT/TianTianJunQi/Perception/PerfKit.swift" \
  "$ROOT/TianTianJunQi/Perception/PixelBufferRenderer.swift" \
  "$ROOT/TianTianJunQi/Perception/PieceCatalog.swift" \
  "$ROOT/TianTianJunQi/Perception/PopupResolver.swift" \
  "$ROOT/TianTianJunQi/Perception/ScreenState.swift" \
  "$ROOT/TianTianJunQi/Perception/SnapshotLibrary.swift" \
  "$ROOT/TianTianJunQi/Runtime/CaptureFrame.swift" \
  "$ROOT/TianTianJunQi/Storage/StorageKit.swift" \
  "$ROOT/Tests/SwiftPerception/main.swift" \
  -o "$BUILD_DIR/perception-tests"

"$BUILD_DIR/perception-tests"
