"""样本库 → Create ML 图像数据集导出（M1-3）。

输入：`perception/samples/snapshot-*/`（整帧 + 60 格 + meta.json + labels.json）
输出：按状态/颜色/棋子分目录的图像 + labels.csv + manifest.json。

约定：
- 只导出已标为 empty / hidden / revealed 的格子；unknown 跳过。
- 状态分类使用全部已标格；颜色/棋子分类只使用完整明子。
- 输出目录必须不存在或为空，避免不同批次标签混在一起。
"""

from __future__ import annotations

import csv
import json
import shutil
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_SAMPLES_ROOT = (
    Path.home()
    / "Library"
    / "Application Support"
    / "TianTianJunqiAI"
    / "perception"
    / "samples"
)
DEFAULT_DATASETS_ROOT = (
    Path.home() / "Library" / "Application Support" / "TianTianJunqiAI" / "datasets"
)

STATE_CLASSES = ("empty", "hidden", "revealed")
COLOR_CLASSES = ("red", "black")
PIECE_IDS = {
    "司令": "commander",
    "军长": "army_commander",
    "师长": "division_commander",
    "旅长": "brigade_commander",
    "团长": "regiment_commander",
    "营长": "battalion_commander",
    "连长": "company_commander",
    "排长": "platoon_commander",
    "工兵": "engineer",
    "地雷": "mine",
    "炸弹": "bomb",
    "军旗": "flag",
}

CSV_FIELDS = [
    "snapshot",
    "row",
    "col",
    "index",
    "state",
    "color",
    "piece",
    "piece_id",
    "state_file",
    "color_file",
    "piece_file",
]


class DatasetExportError(RuntimeError):
    """样本不足或目录状态不允许导出。"""


@dataclass
class ExportSummary:
    out: Path
    snapshots: int
    cells: int
    state_counts: dict[str, int] = field(default_factory=dict)
    color_counts: dict[str, int] = field(default_factory=dict)
    piece_counts: dict[str, int] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "version": 1,
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "snapshots": self.snapshots,
            "cells": self.cells,
            "stateCounts": self.state_counts,
            "colorCounts": self.color_counts,
            "pieceCounts": self.piece_counts,
            "warnings": self.warnings,
        }


def export_samples(samples_root: Path, out_root: Path) -> ExportSummary:
    """把带 labels.json 的快照导出为分层图像目录。"""
    samples_root = Path(samples_root)
    out_root = Path(out_root)
    if not samples_root.is_dir():
        raise DatasetExportError(f"样本目录不存在：{samples_root}")
    if out_root.exists() and any(out_root.iterdir()):
        raise DatasetExportError(f"输出目录已存在且非空：{out_root}")
    out_root.mkdir(parents=True, exist_ok=True)

    summary = ExportSummary(
        out=out_root,
        snapshots=0,
        cells=0,
        state_counts={name: 0 for name in STATE_CLASSES},
        color_counts={name: 0 for name in COLOR_CLASSES},
        piece_counts={name: 0 for name in PIECE_IDS.values()},
    )
    rows: list[dict[str, str | int]] = []
    labeled_snapshots = 0

    for snapshot_dir in sorted(samples_root.glob("snapshot-*")):
        if not snapshot_dir.is_dir():
            continue
        labels_path = snapshot_dir / "labels.json"
        if not labels_path.is_file():
            summary.warnings.append(f"{snapshot_dir.name}: 缺少 labels.json，跳过")
            continue
        try:
            meta = json.loads((snapshot_dir / "meta.json").read_text(encoding="utf-8"))
            labels = json.loads(labels_path.read_text(encoding="utf-8"))
            cells = _validated_cells(snapshot_dir, meta, labels)
        except (OSError, json.JSONDecodeError, ValueError) as error:
            summary.warnings.append(f"{snapshot_dir.name}: {error}")
            continue

        labeled_snapshots += 1
        for cell, label in cells:
            state = label["state"]
            if state not in STATE_CLASSES:
                summary.warnings.append(
                    f"{snapshot_dir.name}: 格子 {cell['index']} 状态 {state!r} 未导出"
                )
                continue
            source = snapshot_dir / str(cell["file"])
            if not source.is_file():
                summary.warnings.append(
                    f"{snapshot_dir.name}: 缺少格子图片 {cell['file']}"
                )
                continue

            row = int(cell["row"])
            col = int(cell["col"])
            index = int(cell["index"])
            base_name = f"{snapshot_dir.name}_r{row:02d}c{col:02d}.png"

            state_file = _copy(source, out_root / "state" / state / base_name)
            color_file = ""
            piece_file = ""
            piece_id = ""

            if state == "revealed":
                color = label.get("color")
                if color in COLOR_CLASSES:
                    color_file = _copy(source, out_root / "color" / color / base_name)
                else:
                    summary.warnings.append(
                        f"{snapshot_dir.name}: 格子 {index} 明子缺少合法颜色"
                    )

                piece = label.get("piece")
                if piece in PIECE_IDS:
                    piece_id = PIECE_IDS[piece]
                    piece_file = _copy(source, out_root / "piece" / piece_id / base_name)
                else:
                    summary.warnings.append(
                        f"{snapshot_dir.name}: 格子 {index} 明子缺少合法棋子"
                    )

            summary.state_counts[state] += 1
            if color_file:
                summary.color_counts[label["color"]] += 1
            if piece_file:
                summary.piece_counts[piece_id] += 1
            rows.append(
                {
                    "snapshot": snapshot_dir.name,
                    "row": row,
                    "col": col,
                    "index": index,
                    "state": state,
                    "color": label.get("color") or "",
                    "piece": label.get("piece") or "",
                    "piece_id": piece_id,
                    "state_file": _relative(state_file, out_root),
                    "color_file": _relative(color_file, out_root) if color_file else "",
                    "piece_file": _relative(piece_file, out_root) if piece_file else "",
                }
            )

    if not rows:
        raise DatasetExportError(
            f"没有可导出的标签；请先在客户端「样本库」里标注至少一份快照（{samples_root}）"
        )

    summary.snapshots = labeled_snapshots
    summary.cells = len(rows)
    _write_csv(out_root / "labels.csv", rows)
    (out_root / "manifest.json").write_text(
        json.dumps(summary.as_dict(), ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return summary


def _validated_cells(
    snapshot_dir: Path,
    meta: dict,
    labels: dict,
) -> list[tuple[dict, dict]]:
    rows = int(meta.get("rows", 0))
    cols = int(meta.get("cols", 0))
    if rows <= 0 or cols <= 0:
        raise ValueError("meta.json 行列无效")
    if int(labels.get("rows", 0)) != rows or int(labels.get("cols", 0)) != cols:
        raise ValueError("labels.json 行列与 meta.json 不一致")
    meta_cells = meta.get("cells")
    label_cells = labels.get("cells")
    if not isinstance(meta_cells, list) or len(meta_cells) != rows * cols:
        raise ValueError(f"meta.json 格数不是 {rows * cols}")
    if not isinstance(label_cells, list) or len(label_cells) != rows * cols:
        raise ValueError(f"labels.json 格数不是 {rows * cols}")

    labels_by_index = {
        int(item.get("index", -1)): item
        for item in label_cells
        if isinstance(item, dict)
    }
    if len(labels_by_index) != len(label_cells):
        raise ValueError("labels.json 存在重复/缺失的 index")

    result: list[tuple[dict, dict]] = []
    for cell in meta_cells:
        if not isinstance(cell, dict):
            raise ValueError("meta.json 格子格式无效")
        index = int(cell.get("index", -1))
        label = labels_by_index.get(index)
        if label is None:
            raise ValueError(f"labels.json 缺少格子 {index}")
        result.append((cell, label))
    return result


def _copy(source: Path, destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    return destination


def _relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def _write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)
