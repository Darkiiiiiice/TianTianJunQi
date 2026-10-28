"""样本库导出测试：labels.json → 去重 + 会话分组的 Create ML 分层目录。"""

from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path

import pytest

from wgai.cli import main
from wgai.dataset import PIECE_IDS, DatasetExportError, export_samples


def write_snapshot(
    root: Path,
    name: str,
    labels_by_index: dict[int, dict] | None,
    rows: int = 2,
    cols: int = 2,
    cell_bytes=None,
) -> Path:
    folder = root / name
    (folder / "cells").mkdir(parents=True)
    (folder / "frame.png").write_bytes(b"frame")
    cells = []
    for index in range(rows * cols):
        row, col = divmod(index, cols)
        file = f"cells/r{row:02d}c{col:02d}.png"
        payload = (
            cell_bytes(index)
            if cell_bytes is not None
            else f"{name}-cell-{index}".encode()
        )
        (folder / file).write_bytes(payload)
        cells.append(
            {
                "index": index,
                "row": row,
                "col": col,
                "file": file,
                "center": {"x": (col + 0.5) / cols, "y": (row + 0.5) / rows},
            }
        )
    meta = {
        "createdAt": "2026-10-26T00:00:00Z",
        "rows": rows,
        "cols": cols,
        "windowSize": {"width": 505, "height": 328},
        "theme": "test",
        "frameFile": "frame.png",
        "cellSize": 128,
        "boardCorners": [
            {"x": 0, "y": 0},
            {"x": 1, "y": 0},
            {"x": 1, "y": 1},
            {"x": 0, "y": 1},
        ],
        "contentPixelSize": {"width": 960, "height": 600},
        "cells": cells,
    }
    (folder / "meta.json").write_text(json.dumps(meta), encoding="utf-8")

    if labels_by_index is not None:
        label_cells = []
        for index in range(rows * cols):
            row, col = divmod(index, cols)
            spec = labels_by_index.get(index, {"state": "unknown"})
            label_cells.append({"index": index, "row": row, "col": col, **spec})
        labels = {
            "version": 1,
            "snapshot": name,
            "rows": rows,
            "cols": cols,
            "updatedAt": "2026-10-26T00:00:00Z",
            "cells": label_cells,
        }
        (folder / "labels.json").write_text(json.dumps(labels), encoding="utf-8")
    return folder


def test_export_samples_layers(tmp_path: Path) -> None:
    samples = tmp_path / "samples"
    write_snapshot(
        samples,
        "snapshot-20261026-000001-000",
        {
            0: {"state": "empty"},
            1: {"state": "hidden"},
            2: {"state": "revealed", "color": "red", "piece": "司令"},
            3: {"state": "hidden"},
        },
    )
    write_snapshot(
        samples,
        "snapshot-20261026-000002-000",
        {
            0: {"state": "hidden"},
            1: {"state": "empty"},
            2: {"state": "revealed", "color": "black", "piece": "炸弹"},
            3: {"state": "hidden"},
        },
    )

    out = tmp_path / "out"
    summary = export_samples(samples, out)

    assert summary.snapshots == 2
    assert summary.cells == 8
    assert summary.images == 8
    assert summary.state_counts == {"empty": 2, "hidden": 4, "revealed": 2}
    assert summary.color_counts == {"red": 1, "black": 1}
    assert summary.piece_counts["commander"] == 1
    assert summary.piece_counts["bomb"] == 1
    assert all("找不到指定的验证会话" not in warning for warning in summary.warnings)
    assert any("无法划分验证集" in warning for warning in summary.warnings)

    train = summary.splits["train"]
    assert train.images == 8
    assert summary.splits["val"].images == 0
    assert len(list((out / "train" / "state" / "empty").glob("*.png"))) == 2
    assert len(list((out / "train" / "color" / "red").glob("*.png"))) == 1
    assert len(list((out / "train" / "piece" / "commander").glob("*.png"))) == 1
    assert not (out / "val").exists()

    with (out / "labels.csv").open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == 8
    assert {row["split"] for row in rows} == {"train"}
    for row in rows:
        assert (out / row["state_file"]).is_file()
        if row["state"] == "revealed":
            assert (out / row["color_file"]).is_file()
            assert (out / row["piece_file"]).is_file()
        else:
            assert row["color_file"] == ""
            assert row["piece_file"] == ""

    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == 3
    assert manifest["cells"] == 8
    assert manifest["images"] == 8
    assert manifest["splits"]["train"]["stateCounts"] == summary.state_counts


def test_export_deduplicates_identical_cells(tmp_path: Path) -> None:
    """棋盘不动的格子会在连续快照里重复，导出必须按内容哈希去重。"""
    samples = tmp_path / "samples"
    same = {"state": "hidden"}
    write_snapshot(samples, "snapshot-20261026-000001-000", {0: same, 1: same},
                   cell_bytes=lambda index: b"same")
    write_snapshot(samples, "snapshot-20261026-000002-000", {0: same, 1: same},
                   cell_bytes=lambda index: b"same")

    out = tmp_path / "out"
    summary = export_samples(samples, out)

    assert summary.cells == 4
    assert summary.images == 1
    assert summary.state_counts == {"empty": 0, "hidden": 1, "revealed": 0}
    assert len(list((out / "train" / "state" / "hidden").glob("*.png"))) == 1
    assert summary.leaked_images == 0


def test_export_splits_by_session(tmp_path: Path) -> None:
    """两个相隔 10 分钟的快照属不同会话，较小的会话做验证集。"""
    samples = tmp_path / "samples"
    labels = {
        0: {"state": "empty"},
        1: {"state": "hidden"},
        2: {"state": "revealed", "color": "red", "piece": "工兵"},
        3: {"state": "hidden"},
    }
    write_snapshot(samples, "snapshot-20261026-000000-000", labels)
    for minute in ("001000", "001100", "001200"):
        write_snapshot(samples, f"snapshot-20261026-{minute}-000", labels)

    out = tmp_path / "out"
    summary = export_samples(samples, out)

    assert [session.name for session in summary.sessions] == ["S0", "S1"]
    assert summary.sessions[0].split == "val"
    assert summary.sessions[1].split == "train"
    assert summary.sessions[0].snapshots == 1
    assert summary.sessions[1].snapshots == 3
    # 同一会话内的唯一图只属于一个 split，不跨集。
    assert summary.splits["val"].images == 4
    assert summary.splits["train"].images == 12
    assert len(list((out / "val" / "state" / "hidden").glob("*.png"))) == 2


def test_export_drops_leaked_images_from_val(tmp_path: Path) -> None:
    """同一张图同时出现在训练与验证会话时归入 train，避免近邻泄漏。"""
    samples = tmp_path / "samples"
    labels = {0: {"state": "hidden"}, 1: {"state": "hidden"}}
    # S0（验证会话）里 index0 与 S1 里的 index0 内容完全相同。
    write_snapshot(
        samples,
        "snapshot-20261026-000000-000",
        labels,
        cell_bytes=lambda index: b"shared" if index == 0 else b"only-val",
    )
    write_snapshot(
        samples,
        "snapshot-20261026-001000-000",
        labels,
        cell_bytes=lambda index: b"shared" if index == 0 else b"only-train-1",
    )
    write_snapshot(
        samples,
        "snapshot-20261026-002000-000",
        labels,
        cell_bytes=lambda index: b"shared" if index == 0 else b"only-train-2",
    )

    out = tmp_path / "out"
    summary = export_samples(samples, out)

    assert len(summary.sessions) == 3
    assert summary.sessions[0].split == "val"
    assert summary.leaked_images == 1

    with (out / "labels.csv").open(encoding="utf-8", newline="") as handle:
        rows = {row["sha256"]: row for row in csv.DictReader(handle)}
    shared = hashlib.sha256(b"shared").hexdigest()
    assert rows[shared]["split"] == "train"
    assert rows[shared]["session"] == "S0"
    # 该共享图只出现在 train 目录，val 目录里没有；val 只剩 1 张独有图。
    assert summary.splits["val"].images == 1
    val_names = {path.name for path in (out / "val").rglob("*.png")}
    assert rows[shared]["state_file"].split("/")[-1] not in val_names


def test_export_explicit_val_session(tmp_path: Path) -> None:
    samples = tmp_path / "samples"
    labels = {0: {"state": "hidden"}}
    write_snapshot(samples, "snapshot-20261026-000000-000", labels)
    write_snapshot(samples, "snapshot-20261026-001000-000", labels)
    write_snapshot(samples, "snapshot-20261026-002000-000", labels)

    out = tmp_path / "out"
    summary = export_samples(samples, out, val_session="S2")
    assert summary.splits["val"].images == 1
    assert summary.splits["train"].images == 2

    with pytest.raises(DatasetExportError, match="找不到指定的验证会话"):
        export_samples(samples, tmp_path / "out2", val_session="S9")


def test_export_splits_three_way_with_test(tmp_path: Path) -> None:
    samples = tmp_path / "samples"
    labels = {
        0: {"state": "empty"},
        1: {"state": "hidden"},
        2: {"state": "revealed", "color": "red", "piece": "司令"},
        3: {"state": "hidden"},
    }
    for minute in ("000000", "001000", "002000", "003000"):
        write_snapshot(samples, f"snapshot-20261026-{minute}-000", labels)

    out = tmp_path / "out"
    summary = export_samples(samples, out, val_session="S1", test_session="S3")

    assert [session.split for session in summary.sessions] == [
        "train",
        "val",
        "train",
        "test",
    ]
    assert summary.splits["train"].images == 8
    assert summary.splits["val"].images == 4
    assert summary.splits["test"].images == 4

    with (out / "labels.csv").open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert {row["split"] for row in rows} == {"train", "val", "test"}

    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == 3
    assert set(manifest["splits"]) == {"train", "val", "test"}


def test_export_rejects_same_val_and_test_session(tmp_path: Path) -> None:
    samples = tmp_path / "samples"
    labels = {0: {"state": "hidden"}}
    for minute in ("000000", "001000", "002000"):
        write_snapshot(samples, f"snapshot-20261026-{minute}-000", labels)

    with pytest.raises(DatasetExportError, match="不能与测试会话相同"):
        export_samples(samples, tmp_path / "out", val_session="S2", test_session="S2")


def test_export_three_way_needs_three_sessions(tmp_path: Path) -> None:
    samples = tmp_path / "samples"
    labels = {0: {"state": "hidden"}}
    write_snapshot(samples, "snapshot-20261026-000000-000", labels)
    write_snapshot(samples, "snapshot-20261026-001000-000", labels)

    with pytest.raises(DatasetExportError, match="至少需要 3 个会话"):
        export_samples(samples, tmp_path / "out", test_session="S1")


def test_export_skips_unknown_and_missing_labels(tmp_path: Path) -> None:
    samples = tmp_path / "samples"
    write_snapshot(
        samples,
        "snapshot-20261026-000001-000",
        {0: {"state": "hidden"}, 1: {"state": "unknown"}},
    )
    write_snapshot(samples, "snapshot-20261026-000002-000", None)

    out = tmp_path / "out"
    summary = export_samples(samples, out)

    assert summary.cells == 1
    assert summary.images == 1
    assert summary.state_counts["hidden"] == 1
    assert any("缺少 labels.json" in warning for warning in summary.warnings)
    assert any("unknown" in warning for warning in summary.warnings)


def test_export_requires_labels(tmp_path: Path) -> None:
    samples = tmp_path / "samples"
    write_snapshot(samples, "snapshot-20261026-000001-000", None)
    with pytest.raises(DatasetExportError, match="没有可导出"):
        export_samples(samples, tmp_path / "out")


def test_export_rejects_non_empty_output(tmp_path: Path) -> None:
    samples = tmp_path / "samples"
    write_snapshot(
        samples,
        "snapshot-20261026-000001-000",
        {0: {"state": "hidden"}},
    )
    out = tmp_path / "out"
    out.mkdir()
    (out / "keep.txt").write_text("keep", encoding="utf-8")
    with pytest.raises(DatasetExportError, match="非空"):
        export_samples(samples, out)
    assert (out / "keep.txt").read_text(encoding="utf-8") == "keep"


def test_export_rejects_mismatched_labels(tmp_path: Path) -> None:
    samples = tmp_path / "samples"
    folder = write_snapshot(
        samples,
        "snapshot-20261026-000001-000",
        {0: {"state": "hidden"}},
    )
    labels_path = folder / "labels.json"
    labels = json.loads(labels_path.read_text(encoding="utf-8"))
    labels["rows"] = 5
    labels_path.write_text(json.dumps(labels), encoding="utf-8")

    with pytest.raises(DatasetExportError, match="没有可导出"):
        export_samples(samples, tmp_path / "out")


def test_piece_id_mapping_is_complete() -> None:
    assert len(PIECE_IDS) == 12
    assert len(set(PIECE_IDS.values())) == 12
    assert PIECE_IDS["司令"] == "commander"
    assert PIECE_IDS["军旗"] == "flag"


def test_dataset_cli(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    samples = tmp_path / "samples"
    write_snapshot(
        samples,
        "snapshot-20261026-000001-000",
        {0: {"state": "hidden"}, 1: {"state": "empty"}},
    )
    out = tmp_path / "out"
    assert main(["dataset", "--input", str(samples), "--out", str(out)]) == 0
    assert (out / "labels.csv").is_file()
    captured = capsys.readouterr()
    assert "已导出" in captured.out
    assert "hidden=1" in captured.out


def test_dataset_cli_without_samples(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    samples = tmp_path / "samples"
    samples.mkdir()
    assert main(["dataset", "--input", str(samples), "--out", str(tmp_path / "out")]) == 2
    captured = capsys.readouterr()
    assert "数据集导出失败" in captured.err
