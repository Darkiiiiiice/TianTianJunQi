import csv
import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from wgai.screen import (
    SCREEN_CLASSES,
    ScreenDatasetError,
    ScreenNet,
    export_screen_dataset,
)


def _write_screen_sample(root: Path, stamp: str, label: str, color) -> Path:
    directory = root / f"screen-{stamp}"
    directory.mkdir(parents=True)
    Image.new("RGB", (64, 48), color).save(directory / "frame.png")
    (directory / "meta.json").write_text(
        json.dumps(
            {
                "version": 1,
                "createdAt": datetime.now(timezone.utc).isoformat(),
                "label": label,
                "source": "test",
                "windowSize": [368, 251],
                "contentPixelSize": [64, 48],
            }
        ),
        encoding="utf-8",
    )
    return directory


def _write_board_snapshot(root: Path, stamp: str, color) -> Path:
    directory = root / f"snapshot-{stamp}"
    directory.mkdir(parents=True)
    Image.new("RGB", (64, 48), color).save(directory / "frame.png")
    (directory / "meta.json").write_text(
        json.dumps({"createdAt": datetime.now(timezone.utc).isoformat(), "frameFile": "frame.png"}),
        encoding="utf-8",
    )
    return directory


def test_export_screen_dataset_keeps_bursts_in_one_split(tmp_path):
    samples = tmp_path / "screen-samples"
    samples.mkdir()
    colors = {
        "main": (255, 0, 0),
        "modeLobby": (0, 255, 0),
        "matching": (0, 0, 255),
        "result": (255, 255, 0),
        "popup": (255, 0, 255),
        "unknown": (0, 255, 255),
    }
    for label_index, (label, color) in enumerate(colors.items()):
        for index, second in enumerate((0, 10, 20)):
            # 每帧颜色略有差异，避免被内容去重折叠。
            shade = tuple(min(255, channel + index * 8) for channel in color)
            _write_screen_sample(
                samples,
                f"20261028-10{label_index:02d}{second:02d}-{index:03d}",
                label,
                shade,
            )
        # 旧标签 venue 应映射到 modeLobby。
        if label == "modeLobby":
            _write_screen_sample(
                samples, "20261028-100030-001", "venue", (1, 2, 3)
            )

    board_root = tmp_path / "board-snapshots"
    board_root.mkdir()
    for index, second in enumerate((0, 10, 20)):
        _write_board_snapshot(
            board_root,
            f"20261028-1100{second:02d}-{index:03d}",
            (10 + index, 20, 30),
        )

    out = tmp_path / "dataset"
    summary = export_screen_dataset(
        samples,
        out,
        board_snapshots_root=board_root,
        burst_gap_seconds=3,
        max_board_samples=0,
        seed=0,
    )

    assert summary.unique_images == 22  # 18 screen + 1 venue + 3 board
    assert summary.splits["train"]["modeLobby"] >= 1

    with (out / "labels.csv").open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == 22
    assert {row["label"] for row in rows} == set(SCREEN_CLASSES)
    assert all((out / row["file"]).is_file() for row in rows)

    # 同一个 burst 不能跨 split。
    split_of_session = {}
    for row in rows:
        split_of_session.setdefault(row["session"], set()).add(row["split"])
    assert all(len(splits) == 1 for splits in split_of_session.values())

    # 每个类别都有 val 与 test（3 个 burst 时各 1 个）。
    for label in SCREEN_CLASSES:
        label_splits = {row["split"] for row in rows if row["label"] == label}
        assert "train" in label_splits
        assert "val" in label_splits
        assert "test" in label_splits

    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["classes"] == list(SCREEN_CLASSES)


def test_export_screen_dataset_skips_conflicting_duplicate(tmp_path):
    samples = tmp_path / "screen-samples"
    samples.mkdir()
    _write_screen_sample(samples, "20261028-100000-000", "main", (255, 0, 0))
    duplicate = _write_screen_sample(samples, "20261028-100010-000", "unknown", (255, 0, 0))
    assert duplicate.is_dir()
    _write_screen_sample(samples, "20261028-100020-000", "popup", (0, 0, 255))

    summary = export_screen_dataset(
        samples, tmp_path / "dataset", board_snapshots_root=None, max_board_samples=0
    )
    assert summary.unique_images == 1
    assert any("标签冲突" in warning for warning in summary.skipped)


def test_export_screen_dataset_rejects_empty_root(tmp_path):
    empty = tmp_path / "empty"
    empty.mkdir()
    with pytest.raises(ScreenDatasetError):
        export_screen_dataset(
            empty, tmp_path / "dataset", board_snapshots_root=None, max_board_samples=0
        )


def test_screen_net_output_shape():
    import mlx.core as mx

    model = ScreenNet(len(SCREEN_CLASSES), input_size=64)
    output = np.asarray(model(mx.zeros((2, 64, 64, 3), dtype=mx.float32)))
    assert output.shape == (2, len(SCREEN_CLASSES))
