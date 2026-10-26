"""样本库导出测试：labels.json → Create ML 分层目录 + CSV。"""

from __future__ import annotations

import csv
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
) -> Path:
    folder = root / name
    (folder / "cells").mkdir(parents=True)
    (folder / "frame.png").write_bytes(b"frame")
    cells = []
    for index in range(rows * cols):
        row, col = divmod(index, cols)
        file = f"cells/r{row:02d}c{col:02d}.png"
        (folder / file).write_bytes(f"cell-{index}".encode())
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
        "boardCorners": [{"x": 0, "y": 0}, {"x": 1, "y": 0}, {"x": 1, "y": 1}, {"x": 0, "y": 1}],
        "contentPixelSize": {"width": 960, "height": 600},
        "cells": cells,
    }
    (folder / "meta.json").write_text(json.dumps(meta), encoding="utf-8")

    if labels_by_index is not None:
        label_cells = []
        for index in range(rows * cols):
            row, col = divmod(index, cols)
            spec = labels_by_index.get(index, {"state": "unknown"})
            label_cells.append(
                {"index": index, "row": row, "col": col, **spec}
            )
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
    assert summary.state_counts == {"empty": 2, "hidden": 4, "revealed": 2}
    assert summary.color_counts == {"red": 1, "black": 1}
    assert summary.piece_counts["commander"] == 1
    assert summary.piece_counts["bomb"] == 1
    assert summary.warnings == []

    for state, count in summary.state_counts.items():
        assert len(list((out / "state" / state).glob("*.png"))) == count
    assert len(list((out / "color" / "red").glob("*.png"))) == 1
    assert len(list((out / "color" / "black").glob("*.png"))) == 1
    assert len(list((out / "piece" / "commander").glob("*.png"))) == 1
    assert len(list((out / "piece" / "bomb").glob("*.png"))) == 1

    with (out / "labels.csv").open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == 8
    assert {row["snapshot"] for row in rows} == {
        "snapshot-20261026-000001-000",
        "snapshot-20261026-000002-000",
    }
    for row in rows:
        assert (out / row["state_file"]).is_file()
        if row["state"] == "revealed":
            assert (out / row["color_file"]).is_file()
            assert (out / row["piece_file"]).is_file()
        else:
            assert row["color_file"] == ""
            assert row["piece_file"] == ""

    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["cells"] == 8
    assert manifest["stateCounts"] == summary.state_counts


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
