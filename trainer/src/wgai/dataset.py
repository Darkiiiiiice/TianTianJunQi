"""样本库 → Create ML 图像数据集导出（M1-3）。

输入：`perception/samples/snapshot-*/`（整帧 + 60 格 + meta.json + labels.json）
输出：`<out>/<split>/{state,color,piece}/<类>/` 图像 + labels.csv + manifest.json。

约定：
- 只导出已标为 empty / hidden / revealed 的格子；unknown 跳过。
- 状态分类使用全部已标格；颜色/棋子分类只使用完整明子。
- 输出目录必须不存在或为空，避免不同批次标签混在一起。
- 按格子图片内容哈希去重：棋盘上不动的棋子会在连续快照里反复出现，
  随机划分会让同一张图同时进训练集和验证集，导致验证准确率虚高。
- 按「对局会话」分组划分 train/val/test，同一会话不跨集；哈希跨会话重复时归入
  train，并从 val/test 中剔除，避免近邻泄漏。
- test 只在显式指定 `--test-session` 时启用；验证集从剩余会话中选，绝不与 test 重叠。
"""

from __future__ import annotations

import csv
import hashlib
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

SPLITS = ("train", "val", "test")

# 相邻快照间隔超过该秒数即视为新的一局/新会话。
SESSION_GAP_SECONDS = 120
# 验证集目标占比：选择一个完整会话作为验证集，使其唯一图数量最接近该比例。
VAL_TARGET_RATIO = 0.2

CSV_FIELDS = [
    "snapshot",
    "session",
    "split",
    "row",
    "col",
    "index",
    "state",
    "color",
    "piece",
    "piece_id",
    "sha256",
    "state_file",
    "color_file",
    "piece_file",
]


class DatasetExportError(RuntimeError):
    """样本不足或目录状态不允许导出。"""


@dataclass
class SplitStats:
    """单个 split 的去重后统计（每类统计唯一图数量）。"""

    split: str
    images: int = 0
    state_counts: dict[str, int] = field(
        default_factory=lambda: {name: 0 for name in STATE_CLASSES}
    )
    color_counts: dict[str, int] = field(
        default_factory=lambda: {name: 0 for name in COLOR_CLASSES}
    )
    piece_counts: dict[str, int] = field(
        default_factory=lambda: {name: 0 for name in PIECE_IDS.values()}
    )

    def as_dict(self) -> dict:
        return {
            "split": self.split,
            "images": self.images,
            "stateCounts": self.state_counts,
            "colorCounts": self.color_counts,
            "pieceCounts": self.piece_counts,
        }


@dataclass
class SessionInfo:
    """一个对局会话（相邻快照间隔 ≤ gap 的连续序列）。"""

    name: str
    first_snapshot: str
    last_snapshot: str
    snapshots: int
    split: str = "train"
    unique_images: int = 0

    def as_dict(self) -> dict:
        return {
            "name": self.name,
            "firstSnapshot": self.first_snapshot,
            "lastSnapshot": self.last_snapshot,
            "snapshots": self.snapshots,
            "split": self.split,
            "uniqueImages": self.unique_images,
        }


@dataclass
class ExportSummary:
    out: Path
    snapshots: int
    cells: int
    images: int
    sessions: list[SessionInfo] = field(default_factory=list)
    splits: dict[str, SplitStats] = field(default_factory=dict)
    skipped_conflicts: int = 0
    leaked_images: int = 0
    warnings: list[str] = field(default_factory=list)

    @property
    def state_counts(self) -> dict[str, int]:
        return self._merge("state_counts")

    @property
    def color_counts(self) -> dict[str, int]:
        return self._merge("color_counts")

    @property
    def piece_counts(self) -> dict[str, int]:
        return self._merge("piece_counts")

    def _merge(self, attribute: str) -> dict[str, int]:
        merged: dict[str, int] = {}
        for stats in self.splits.values():
            for name, count in getattr(stats, attribute).items():
                merged[name] = merged.get(name, 0) + count
        return merged

    def coverage(self) -> dict[str, dict[str, list[str]]]:
        """每个任务的类别在各自 split 里的覆盖率。"""
        result: dict[str, dict[str, list[str]]] = {}
        for task, attribute in (
            ("state", "state_counts"),
            ("color", "color_counts"),
            ("piece", "piece_counts"),
        ):
            result[task] = {}
            for split, stats in self.splits.items():
                counts = getattr(stats, attribute)
                result[task][split] = [name for name, count in counts.items() if count]
        return result

    def as_dict(self) -> dict:
        return {
            "version": 3,
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "snapshots": self.snapshots,
            "cells": self.cells,
            "images": self.images,
            "skippedConflicts": self.skipped_conflicts,
            "leakedImages": self.leaked_images,
            "sessions": [session.as_dict() for session in self.sessions],
            "splits": {name: stats.as_dict() for name, stats in self.splits.items()},
            "coverage": self.coverage(),
            "warnings": self.warnings,
        }


@dataclass
class _Record:
    snapshot: str
    session: str
    split: str
    row: int
    col: int
    index: int
    file: Path
    sha256: str
    state: str
    color: str
    piece: str


def export_samples(
    samples_root: Path,
    out_root: Path,
    *,
    session_gap_seconds: int = SESSION_GAP_SECONDS,
    val_session: str | None = None,
    test_session: str | None = None,
) -> ExportSummary:
    """把带 labels.json 的快照去重后导出为 train/val/test 分层图像目录。

    `test_session` 为空时保持两路划分（train/val），兼容旧流程；指定后强制三路
    划分，且验证会话不能与测试会话相同。
    """
    samples_root = Path(samples_root)
    out_root = Path(out_root)
    if not samples_root.is_dir():
        raise DatasetExportError(f"样本目录不存在：{samples_root}")
    if out_root.exists() and any(out_root.iterdir()):
        raise DatasetExportError(f"输出目录已存在且非空：{out_root}")

    snapshots = sorted(
        path for path in samples_root.glob("snapshot-*") if path.is_dir()
    )
    if not snapshots:
        raise DatasetExportError(f"样本目录下没有快照：{samples_root}")

    summary = ExportSummary(
        out=out_root,
        snapshots=0,
        cells=0,
        images=0,
        splits={name: SplitStats(split=name) for name in SPLITS},
    )

    sessions, session_of = _group_sessions(snapshots, session_gap_seconds)

    records: list[_Record] = []
    for snapshot_dir in snapshots:
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

        session = session_of[snapshot_dir.name]
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

            color = ""
            piece = ""
            if state == "revealed":
                if label.get("color") in COLOR_CLASSES:
                    color = label["color"]
                else:
                    summary.warnings.append(
                        f"{snapshot_dir.name}: 格子 {cell['index']} 明子缺少合法颜色"
                    )
                if label.get("piece") in PIECE_IDS:
                    piece = label["piece"]
                else:
                    summary.warnings.append(
                        f"{snapshot_dir.name}: 格子 {cell['index']} 明子缺少合法棋子"
                    )

            records.append(
                _Record(
                    snapshot=snapshot_dir.name,
                    session=session.name,
                    split="train",
                    row=int(cell["row"]),
                    col=int(cell["col"]),
                    index=int(cell["index"]),
                    file=source,
                    sha256=_sha256(source),
                    state=state,
                    color=color,
                    piece=piece,
                )
            )

    if not records:
        raise DatasetExportError(
            f"没有可导出的标签；请先在客户端「样本库」里标注至少一份快照（{samples_root}）"
        )

    summary.cells = len(records)
    summary.snapshots = len({record.snapshot for record in records})

    unique_by_hash = _group_by_hash(records)
    summary.images = len(unique_by_hash)

    for session in sessions:
        session.unique_images = len(
            {record.sha256 for record in records if record.session == session.name}
        )

    test_name = _resolve_session(sessions, test_session, "测试")
    if test_name is not None and len(sessions) < 3:
        raise DatasetExportError("三路划分至少需要 3 个会话（train/val/test）")

    val_name = _pick_val_session(
        sessions,
        val_session,
        exclude={test_name} if test_name is not None else None,
    )
    for session in sessions:
        if test_name is not None and session.name == test_name:
            session.split = "test"
        elif session.name == val_name:
            session.split = "val"
        else:
            session.split = "train"
    if val_name is None:
        summary.warnings.append(
            "只有一个对局会话，无法划分验证集；全部样本进入 train"
        )
    if not any(session.split == "train" for session in sessions):
        raise DatasetExportError("划分后没有训练会话；请减少 test/val 会话")
    split_of_session = {session.name: session.split for session in sessions}

    out_root.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, str | int]] = []

    for digest, group in sorted(unique_by_hash.items(), key=lambda item: item[0]):
        labels_seen = {(record.state, record.color, record.piece) for record in group}
        if len(labels_seen) > 1:
            summary.skipped_conflicts += 1
            summary.warnings.append(
                f"哈希 {digest[:8]} 存在冲突标签 {sorted(labels_seen)}，整组跳过"
            )
            continue

        group.sort(key=lambda record: record.snapshot)
        canonical = group[0]
        split_set = {split_of_session[record.session] for record in group}
        if len(split_set) > 1:
            # 同一张图同时出现在训练会话与验证会话：归入 train 并从 val 剔除。
            summary.leaked_images += 1
            split = "train"
        else:
            split = next(iter(split_set))

        stats = summary.splits[split]
        base_name = (
            f"{canonical.snapshot}_r{canonical.row:02d}c{canonical.col:02d}"
            f"_{digest[:8]}.png"
        )

        state_file = _copy(canonical.file, out_root / split / "state" / canonical.state / base_name)
        color_file = ""
        piece_file = ""
        piece_id = ""

        if canonical.state == "revealed":
            if canonical.color:
                color_file = _copy(
                    canonical.file,
                    out_root / split / "color" / canonical.color / base_name,
                )
                stats.color_counts[canonical.color] += 1
            if canonical.piece:
                piece_id = PIECE_IDS[canonical.piece]
                piece_file = _copy(
                    canonical.file, out_root / split / "piece" / piece_id / base_name
                )
                stats.piece_counts[piece_id] += 1

        stats.state_counts[canonical.state] += 1
        stats.images += 1
        rows.append(
            {
                "snapshot": canonical.snapshot,
                "session": canonical.session,
                "split": split,
                "row": canonical.row,
                "col": canonical.col,
                "index": canonical.index,
                "state": canonical.state,
                "color": canonical.color,
                "piece": canonical.piece,
                "piece_id": piece_id,
                "sha256": digest,
                "state_file": _relative(state_file, out_root),
                "color_file": _relative(color_file, out_root) if color_file else "",
                "piece_file": _relative(piece_file, out_root) if piece_file else "",
            }
        )

    if not rows:
        raise DatasetExportError("去重后没有可导出的样本")

    for split in ("val", "test"):
        if split == "test" and test_name is None:
            continue
        if summary.splits[split].images == 0:
            summary.warnings.append(f"{split} 集为空；请检查会话划分或标签")

    summary.sessions = sessions
    _write_csv(out_root / "labels.csv", rows)
    (out_root / "manifest.json").write_text(
        json.dumps(summary.as_dict(), ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return summary


def _group_sessions(
    snapshots: list[Path], gap_seconds: int
) -> tuple[list[SessionInfo], dict[str, SessionInfo]]:
    """按快照时间戳间隔把快照切成对局会话（相邻间隔 > gap 即切分）。"""
    groups: list[list[Path]] = []
    current: list[Path] = [snapshots[0]]
    for previous, following in zip(snapshots, snapshots[1:]):
        gap = (_timestamp(following) - _timestamp(previous)).total_seconds()
        if gap > gap_seconds:
            groups.append(current)
            current = [following]
        else:
            current.append(following)
    groups.append(current)

    sessions: list[SessionInfo] = []
    session_of: dict[str, SessionInfo] = {}
    for index, group in enumerate(groups):
        info = SessionInfo(
            name=f"S{index}",
            first_snapshot=group[0].name,
            last_snapshot=group[-1].name,
            snapshots=len(group),
        )
        sessions.append(info)
        for snapshot in group:
            session_of[snapshot.name] = info
    return sessions, session_of


def _timestamp(snapshot_dir: Path) -> datetime:
    """snapshot-YYYYMMDD-HHMMSS-mmm → datetime（用于会话切分）。"""
    parts = snapshot_dir.name.split("-")
    if len(parts) != 4:
        raise DatasetExportError(f"快照目录名不符合 snapshot-YYYYMMDD-HHMMSS-mmm：{snapshot_dir.name}")
    return datetime.strptime("".join(parts[1:]), "%Y%m%d%H%M%S%f")


def _resolve_session(
    sessions: list[SessionInfo], value: str | None, label: str
) -> str | None:
    """把会话名/首快照名/末快照名解析为会话名；为空返回 None。"""
    if value is None:
        return None
    for session in sessions:
        if value in (session.name, session.first_snapshot, session.last_snapshot):
            return session.name
    raise DatasetExportError(
        f"找不到指定的{label}会话 {value!r}；可选："
        + "、".join(f"{s.name}({s.first_snapshot})" for s in sessions)
    )


def _pick_val_session(
    sessions: list[SessionInfo],
    explicit: str | None,
    exclude: set[str] | None = None,
) -> str | None:
    """选一个完整会话作为验证集，显式排除测试会话。

    显式指定时按其名称或首/末快照名匹配；否则选唯一图数量最接近
    `VAL_TARGET_RATIO * 候选会话唯一图数` 的会话。
    """
    excluded = exclude or set()
    candidates = [session for session in sessions if session.name not in excluded]
    if not candidates:
        return None

    if explicit:
        for session in candidates:
            if explicit in (session.name, session.first_snapshot, session.last_snapshot):
                return session.name
        for session in sessions:
            if explicit in (session.name, session.first_snapshot, session.last_snapshot):
                raise DatasetExportError("验证会话不能与测试会话相同")
        raise DatasetExportError(
            f"找不到指定的验证会话 {explicit!r}；可选："
            + "、".join(f"{s.name}({s.first_snapshot})" for s in candidates)
        )

    if len(sessions) < 2:
        return None

    total = sum(session.unique_images for session in candidates)
    target = total * VAL_TARGET_RATIO

    def score(session: SessionInfo) -> tuple[float, str]:
        return (abs(session.unique_images - target), session.name)

    return min(candidates, key=score).name


def _group_by_hash(records: list[_Record]) -> dict[str, list[_Record]]:
    grouped: dict[str, list[_Record]] = {}
    for record in records:
        grouped.setdefault(record.sha256, []).append(record)
    return grouped


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def _write_csv(path: Path, rows: list[dict[str, str | int]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)
