#!/bin/zsh
# M1-9 离线回放基准：复用 app 的 Core ML 模型与感知内核，测感知 → 动作延迟。
# 用法：scripts/run-perf-bench.sh [--boards N] [--screens N] [--out report.json]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ttj-perf-bench.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

APP="${TTJ_APP:-}"
if [[ -z "$APP" ]]; then
  APP="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/TianTianJunQi-*/Build/Products/Debug/TianTianJunQi.app 2>/dev/null | head -1)"
fi
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "找不到 TianTianJunQi.app；先 xcodebuild 构建，或设置 TTJ_APP=/path/to/TianTianJunQi.app" >&2
  exit 1
fi

OUT="${PERF_OUT:-$HOME/Library/Application Support/TianTianJunqiAI/perception/performance/perf-replay-$(date +%Y%m%d-%H%M%S).json}"

swiftc -O -o "$BUILD_DIR/perf-bench" \
  "$ROOT/TianTianJunQi/Runtime/CaptureFrame.swift" \
  "$ROOT/TianTianJunQi/Perception/PerfKit.swift" \
  "$ROOT/TianTianJunQi/Perception/PixelBufferRenderer.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardGeometry.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardStabilizer.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardStateBuilder.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardPieceClassifier.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardSnapshotExporter.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardTap.swift" \
  "$ROOT/TianTianJunQi/Perception/BoardTurnReader.swift" \
  "$ROOT/TianTianJunQi/Perception/GameState.swift" \
  "$ROOT/TianTianJunQi/Perception/OCRText.swift" \
  "$ROOT/TianTianJunQi/Perception/PieceCatalog.swift" \
  "$ROOT/TianTianJunQi/Perception/PopupResolver.swift" \
  "$ROOT/TianTianJunQi/Perception/ScreenAnalyzer.swift" \
  "$ROOT/TianTianJunQi/Perception/ScreenClassifier.swift" \
  "$ROOT/TianTianJunQi/Perception/ScreenState.swift" \
  "$ROOT/TianTianJunQi/Storage/StorageKit.swift" \
  "$ROOT/Tests/PerfBench/main.swift"

"$BUILD_DIR/perf-bench" \
  --app "$APP" \
  --boards "${PERF_BOARDS:-30}" \
  --screens "${PERF_SCREENS:-20}" \
  --out "$OUT" \
  "$@"
