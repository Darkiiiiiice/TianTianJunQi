"""屏幕分类器数据集 / 训练 / Core ML 导出（M1-7）。

与 M1-3 的棋子分类器分开：输入是完整窗口内容区，标签是 7 个界面状态：

    main / modeLobby / matching / board / result / popup / unknown

数据来源：
- 客户端概览页「采集屏幕」写入 `perception/screen-samples/screen-*/`
  （frame.png + meta.json，meta.label 为人工标签）；
- 可选把 `perception/samples/snapshot-*/frame.png` 当作 board 类补充样本，
  这些快照只在对局界面自动/手动采集，标签可靠。

划分策略：同一类别内按「连拍 burst」分组，burst 不跨 split，避免同一静止界面
的相邻帧同时进入训练和验证集。每个类别单独保证 val/test（样本足够时）。
"""

from __future__ import annotations

import csv
import hashlib
import json
import random
import shutil
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
import numpy as np
from mlx.utils import tree_flatten
from PIL import Image

from wgai.train import classification_metrics

SCREEN_CLASSES = (
    "main",
    "modeLobby",
    "matching",
    "board",
    "result",
    "popup",
    "unknown",
)
SCREEN_LABEL_ALIASES = {"venue": "modeLobby"}

DEFAULT_SCREEN_SAMPLES_ROOT = (
    Path.home()
    / "Library"
    / "Application Support"
    / "TianTianJunqiAI"
    / "perception"
    / "screen-samples"
)
DEFAULT_BOARD_SAMPLES_ROOT = (
    Path.home()
    / "Library"
    / "Application Support"
    / "TianTianJunqiAI"
    / "perception"
    / "samples"
)
DEFAULT_SCREEN_DATASETS_ROOT = (
    Path.home() / "Library" / "Application Support" / "TianTianJunqiAI" / "datasets"
)

BURST_GAP_SECONDS = 3.0
VAL_RATIO = 0.15
TEST_RATIO = 0.15
DEFAULT_MAX_BOARD_SAMPLES = 240
DEFAULT_IMAGE_SIZE = 192
DEFAULT_EPOCHS = 40
DEFAULT_BATCH_SIZE = 32
DEFAULT_LR = 1e-3
DEFAULT_SEED = 0

CSV_FIELDS = ["sample", "source", "session", "split", "label", "file", "sha256"]


class ScreenDatasetError(RuntimeError):
    """屏幕样本不足或目录状态不允许导出。"""


class ScreenTrainError(RuntimeError):
    """屏幕分类器训练配置非法。"""


@dataclass
class ScreenRecord:
    sample: str
    source: str
    label: str
    created: datetime
    path: Path
    sha256: str
    burst: str = ""


@dataclass
class ScreenExportSummary:
    out: Path
    samples: int
    unique_images: int
    splits: dict[str, dict[str, int]] = field(default_factory=dict)
    sources: dict[str, int] = field(default_factory=dict)
    skipped: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "version": 1,
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "samples": self.samples,
            "uniqueImages": self.unique_images,
            "classes": list(SCREEN_CLASSES),
            "splits": self.splits,
            "sources": self.sources,
            "skipped": self.skipped,
            "warnings": self.warnings,
        }


# MARK: - 数据集导出


def export_screen_dataset(
    samples_root: Path,
    out_root: Path,
    *,
    board_snapshots_root: Path | None = None,
    burst_gap_seconds: float = BURST_GAP_SECONDS,
    val_ratio: float = VAL_RATIO,
    test_ratio: float = TEST_RATIO,
    max_board_samples: int = DEFAULT_MAX_BOARD_SAMPLES,
    seed: int = DEFAULT_SEED,
) -> ScreenExportSummary:
    """扫描屏幕样本（可选并入棋盘快照），按 burst 划分并复制到分层目录。"""
    samples_root = Path(samples_root).expanduser()
    out_root = Path(out_root).expanduser()
    if not samples_root.is_dir():
        raise ScreenDatasetError(f"屏幕样本目录不存在：{samples_root}")
    if out_root.exists() and any(out_root.iterdir()):
        raise ScreenDatasetError(f"输出目录已存在且非空：{out_root}")

    records = _load_screen_samples(samples_root)
    if board_snapshots_root is not None:
        records += _load_board_snapshots(Path(board_snapshots_root).expanduser())
    if not records:
        raise ScreenDatasetError(
            f"没有可用样本；先在客户端概览页采集屏幕样本（{samples_root}）"
        )

    summary = ScreenExportSummary(out=out_root, samples=len(records), unique_images=0)
    for record in records:
        summary.sources[record.source] = summary.sources.get(record.source, 0) + 1

    records = _deduplicate(records, summary)
    records = _limit_board_samples(records, max_board_samples, summary)
    summary.unique_images = len(records)

    missing = [name for name in SCREEN_CLASSES if not any(r.label == name for r in records)]
    if missing:
        summary.warnings.append("缺少类别：" + "、".join(missing))

    _assign_bursts(records, burst_gap_seconds)
    splits = _split_bursts(records, val_ratio=val_ratio, test_ratio=test_ratio, seed=seed)
    if not any(split == "train" for split in splits.values()):
        raise ScreenDatasetError("划分后没有训练样本；请检查 burst/split 设置")

    out_root.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, str]] = []
    for split in ("train", "val", "test"):
        summary.splits[split] = {name: 0 for name in SCREEN_CLASSES}

    for record in sorted(records, key=lambda item: (item.label, item.created, item.sample)):
        split = splits[record.burst]
        destination = (
            out_root
            / split
            / record.label
            / f"{record.sha256[:8]}_{record.sample}.png"
        )
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(record.path, destination)
        summary.splits[split][record.label] += 1
        rows.append(
            {
                "sample": record.sample,
                "source": record.source,
                "session": record.burst,
                "split": split,
                "label": record.label,
                "file": destination.relative_to(out_root).as_posix(),
                "sha256": record.sha256,
            }
        )

    for split, counts in summary.splits.items():
        if sum(counts.values()) == 0:
            summary.warnings.append(f"{split} 集为空；请增加采集批次（burst）")
        for name in SCREEN_CLASSES:
            if counts[name] == 0 and any(r.label == name for r in records):
                summary.warnings.append(f"{split} 集缺少类别 {name}")

    _write_csv(out_root / "labels.csv", rows)
    (out_root / "manifest.json").write_text(
        json.dumps(summary.as_dict(), ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return summary


def _load_screen_samples(root: Path) -> list[ScreenRecord]:
    records: list[ScreenRecord] = []
    for directory in sorted(root.glob("screen-*")):
        if not directory.is_dir():
            continue
        meta_path = directory / "meta.json"
        frame_path = directory / "frame.png"
        if not meta_path.is_file() or not frame_path.is_file():
            continue
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            label = str(meta.get("label", ""))
            label = SCREEN_LABEL_ALIASES.get(label, label)
            if label not in SCREEN_CLASSES:
                continue
            records.append(
                ScreenRecord(
                    sample=directory.name,
                    source=str(meta.get("source") or "screen"),
                    label=label,
                    created=_timestamp(directory.name),
                    path=frame_path,
                    sha256=_sha256(frame_path),
                )
            )
        except (OSError, ValueError, json.JSONDecodeError):
            continue
    return records


def _load_board_snapshots(root: Path) -> list[ScreenRecord]:
    records: list[ScreenRecord] = []
    if not root.is_dir():
        return records
    for directory in sorted(root.glob("snapshot-*")):
        if not directory.is_dir():
            continue
        meta_path = directory / "meta.json"
        if not meta_path.is_file():
            continue
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            frame_name = str(meta.get("frameFile") or "frame.png")
            frame_path = directory / frame_name
            if not frame_path.is_file():
                continue
            records.append(
                ScreenRecord(
                    sample=directory.name,
                    source="board-snapshot",
                    label="board",
                    created=_timestamp(directory.name),
                    path=frame_path,
                    sha256=_sha256(frame_path),
                )
            )
        except (OSError, ValueError, json.JSONDecodeError):
            continue
    return records


def _deduplicate(records: list[ScreenRecord], summary: ScreenExportSummary) -> list[ScreenRecord]:
    """按内容哈希去重；同图不同标签的整组跳过，避免训练标签冲突。"""
    by_hash: dict[str, list[ScreenRecord]] = {}
    for record in records:
        by_hash.setdefault(record.sha256, []).append(record)

    result: list[ScreenRecord] = []
    for digest, group in by_hash.items():
        labels = {record.label for record in group}
        if len(labels) > 1:
            summary.skipped.append(
                f"{digest[:8]} 标签冲突 {sorted(labels)}，整组跳过"
            )
            continue
        group.sort(key=lambda record: record.created)
        result.append(group[0])
    return result


def _limit_board_samples(
    records: list[ScreenRecord],
    maximum: int,
    summary: ScreenExportSummary,
) -> list[ScreenRecord]:
    """棋盘快照可能远多于其他类；均匀抽样，保留覆盖整个采集周期的帧。"""
    if maximum <= 0:
        return records
    board = [record for record in records if record.label == "board"]
    if len(board) <= maximum:
        return records
    board.sort(key=lambda record: record.created)
    step = len(board) / maximum
    keep = {id(board[min(int(index * step), len(board) - 1)]) for index in range(maximum)}
    summary.warnings.append(
        f"board 类有 {len(board)} 张，已均匀抽样到 {maximum} 张（--max-board 可调）"
    )
    return [record for record in records if record.label != "board" or id(record) in keep]


def _assign_bursts(records: list[ScreenRecord], gap_seconds: float) -> None:
    """同一来源+标签内，相邻帧间隔 ≤ gap 视为同一 burst。"""
    grouped: dict[tuple[str, str], list[ScreenRecord]] = {}
    for record in records:
        grouped.setdefault((record.source, record.label), []).append(record)
    for (source, label), group in grouped.items():
        group.sort(key=lambda record: record.created)
        current: list[ScreenRecord] = []
        index = 0
        previous: ScreenRecord | None = None
        for record in group:
            if previous is not None and (
                record.created - previous.created
            ).total_seconds() > gap_seconds:
                for item in current:
                    item.burst = f"{source}:{label}:B{index}"
                index += 1
                current = []
            current.append(record)
            previous = record
        for item in current:
            item.burst = f"{source}:{label}:B{index}"


def _split_bursts(
    records: list[ScreenRecord],
    *,
    val_ratio: float,
    test_ratio: float,
    seed: int,
) -> dict[str, str]:
    """按类别把 burst 分到 train/val/test，每个类别尽量都有 val/test。"""
    bursts_by_label: dict[str, dict[str, list[ScreenRecord]]] = {}
    for record in records:
        bursts_by_label.setdefault(record.label, {}).setdefault(record.burst, []).append(record)

    result: dict[str, str] = {}
    for label, bursts in bursts_by_label.items():
        names = sorted(bursts)
        random.Random(f"{seed}:{label}").shuffle(names)
        count = len(names)
        test_count = max(1, round(count * test_ratio)) if count >= 3 else 0
        val_count = max(1, round(count * val_ratio)) if count >= 2 else 0
        if test_count + val_count >= count:
            test_count = 1 if count >= 3 else 0
            val_count = 1 if count >= 2 else 0
        train_count = count - test_count - val_count
        for index, name in enumerate(names):
            if index < train_count:
                result[name] = "train"
            elif index < train_count + val_count:
                result[name] = "val"
            else:
                result[name] = "test"
    return result


def _timestamp(name: str) -> datetime:
    parts = name.split("-")
    if len(parts) < 4:
        raise ScreenDatasetError(f"样本目录名不符合 <前缀>-YYYYMMDD-HHMMSS-mmm：{name}")
    return datetime.strptime("".join(parts[1:4]), "%Y%m%d%H%M%S%f")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


# MARK: - 训练


@dataclass
class ScreenImageSet:
    images: np.ndarray  # uint8, NHWC
    labels: np.ndarray  # int32
    classes: tuple[str, ...]

    def __len__(self) -> int:
        return int(self.labels.shape[0])

    def distribution(self) -> dict[str, int]:
        counts = np.bincount(self.labels, minlength=len(self.classes))
        return {name: int(counts[index]) for index, name in enumerate(self.classes)}


class ScreenConvBlock(nn.Module):
    def __init__(self, in_channels: int, out_channels: int):
        super().__init__()
        self.conv = nn.Conv2d(in_channels, out_channels, 3, padding=1)
        self.norm = nn.BatchNorm(out_channels)
        self.pool = nn.MaxPool2d(2)

    def __call__(self, x: mx.array) -> mx.array:
        return self.pool(nn.relu(self.norm(self.conv(x))))


class ScreenNet(nn.Module):
    """4 层卷积 + 全局平均池化 + 全连接头。

    屏幕状态取决于整体布局，GAP 比展平全连接更稳、参数更少；
    输入固定为 192×192（4 次池化后 12×12）。
    """

    def __init__(self, num_classes: int, input_size: int = DEFAULT_IMAGE_SIZE):
        super().__init__()
        if input_size % 16:
            raise ScreenTrainError(f"图像尺寸需能被 16 整除，当前 {input_size}")
        self.block1 = ScreenConvBlock(3, 32)
        self.block2 = ScreenConvBlock(32, 64)
        self.block3 = ScreenConvBlock(64, 128)
        self.block4 = ScreenConvBlock(128, 128)
        self.pool = nn.AvgPool2d(kernel_size=input_size // 16)
        self.fc1 = nn.Linear(128, 256)
        self.dropout = nn.Dropout(0.2)
        self.fc2 = nn.Linear(256, num_classes)

    def __call__(self, x: mx.array) -> mx.array:
        x = self.block4(self.block3(self.block2(self.block1(x))))
        x = self.pool(x)
        x = x.reshape(x.shape[0], -1)
        x = self.dropout(nn.relu(self.fc1(x)))
        return self.fc2(x)


def train_screen(
    dataset_root: Path,
    out_root: Path,
    *,
    epochs: int = DEFAULT_EPOCHS,
    batch_size: int = DEFAULT_BATCH_SIZE,
    learning_rate: float = DEFAULT_LR,
    image_size: int = DEFAULT_IMAGE_SIZE,
    seed: int = DEFAULT_SEED,
) -> dict:
    """训练 7 类屏幕分类器，输出 model.safetensors / config.json / metrics.json。"""
    dataset_root = Path(dataset_root).expanduser()
    out_root = Path(out_root).expanduser()
    if not (dataset_root / "labels.csv").is_file():
        raise ScreenTrainError(f"数据集缺少 labels.csv：{dataset_root}")

    rows = _read_rows(dataset_root)
    classes = SCREEN_CLASSES
    train_set = _load_images(dataset_root, rows, "train", classes, image_size)
    val_set = _load_images(dataset_root, rows, "val", classes, image_size)
    test_set = _load_images(dataset_root, rows, "test", classes, image_size)
    if not len(train_set):
        raise ScreenTrainError("train 集为空；请检查 screen-dataset 的划分")
    if not len(val_set):
        raise ScreenTrainError("val 集为空；每个类别至少需要 2 个 burst")

    print(
        f"[wgai] screen: train {len(train_set)} 张 / val {len(val_set)} 张"
        + (f" / test {len(test_set)} 张" if len(test_set) else "")
        + f"（{len(classes)} 类，{image_size}px）",
        file=sys.stderr,
    )
    model, best_epoch, val_accuracy = _fit(
        train_set,
        val_set,
        epochs=epochs,
        batch_size=batch_size,
        learning_rate=learning_rate,
        seed=seed,
    )
    y_true, y_pred = _predict(model, val_set, batch_size)
    metrics = classification_metrics(y_true, y_pred, classes)
    metrics["valAccuracy"] = val_accuracy

    test_metrics = None
    if len(test_set):
        test_true, test_pred = _predict(model, test_set, batch_size)
        test_metrics = classification_metrics(test_true, test_pred, classes)

    out_root.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(
        str(out_root / "model.safetensors"),
        dict(tree_flatten(model.parameters())),
    )
    (out_root / "config.json").write_text(
        json.dumps(
            {
                "task": "screen",
                "architecture": "screen-cnn-v1",
                "classes": list(classes),
                "imageSize": image_size,
                "inputLayout": "NHWC",
                "colorOrder": "RGB",
                "scale": 1.0 / 255.0,
                "trainedAt": datetime.now(timezone.utc).isoformat(),
            },
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    result = {
        "task": "screen",
        "classes": list(classes),
        "trainImages": len(train_set),
        "valImages": len(val_set),
        "testImages": len(test_set),
        "epochs": epochs,
        "bestEpoch": best_epoch,
        "trainDistribution": train_set.distribution(),
        "valDistribution": val_set.distribution(),
        "testDistribution": test_set.distribution() if len(test_set) else {},
        "metrics": metrics,
        "testMetrics": test_metrics,
    }
    (out_root / "metrics.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (out_root.parent / "baseline.json").write_text(
        json.dumps(
            {
                "dataset": str(dataset_root),
                "createdAt": datetime.now(timezone.utc).isoformat(),
                "settings": {
                    "epochs": epochs,
                    "batchSize": batch_size,
                    "learningRate": learning_rate,
                    "imageSize": image_size,
                    "seed": seed,
                },
                "result": result,
            },
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    _print_report(result)
    return result


def _read_rows(dataset_root: Path) -> list[dict[str, str]]:
    with (dataset_root / "labels.csv").open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise ScreenTrainError(f"labels.csv 为空：{dataset_root}")
    return rows


def _load_images(
    dataset_root: Path,
    rows: list[dict[str, str]],
    split: str,
    classes: tuple[str, ...],
    image_size: int,
) -> ScreenImageSet:
    class_index = {name: index for index, name in enumerate(classes)}
    arrays: list[np.ndarray] = []
    labels: list[int] = []
    for row in rows:
        if row["split"] != split:
            continue
        label = row["label"]
        if label not in class_index:
            continue
        path = dataset_root / row["file"]
        if not path.is_file():
            raise ScreenTrainError(f"缺少图像：{path}")
        with Image.open(path) as image:
            image = image.convert("RGB")
            if image.size != (image_size, image_size):
                image = image.resize((image_size, image_size), Image.BILINEAR)
            arrays.append(np.asarray(image, dtype=np.uint8))
        labels.append(class_index[label])
    if not arrays:
        return ScreenImageSet(
            images=np.zeros((0, image_size, image_size, 3), dtype=np.uint8),
            labels=np.zeros((0,), dtype=np.int32),
            classes=classes,
        )
    return ScreenImageSet(
        images=np.stack(arrays), labels=np.array(labels, dtype=np.int32), classes=classes
    )


def _fit(
    train_set: ScreenImageSet,
    val_set: ScreenImageSet,
    *,
    epochs: int,
    batch_size: int,
    learning_rate: float,
    seed: int,
) -> tuple[ScreenNet, int, float]:
    mx.random.seed(seed)
    generator = np.random.default_rng(seed)
    model = ScreenNet(len(train_set.classes), train_set.images.shape[1])
    optimizer = optim.AdamW(learning_rate=learning_rate, weight_decay=0.01)
    class_weights = mx.array(_class_weights(train_set.labels, len(train_set.classes)))

    def loss_fn(model: ScreenNet, x: mx.array, y: mx.array) -> mx.array:
        logits = model(x)
        log_probs = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
        picked = mx.take_along_axis(log_probs, y[:, None], axis=1).squeeze(-1)
        return -(picked * mx.take(class_weights, y)).mean()

    loss_and_grad = nn.value_and_grad(model, loss_fn)
    best_accuracy = -1.0
    best_epoch = 0
    best_params = None
    patience = max(8, epochs // 4)
    stale = 0

    for epoch in range(1, epochs + 1):
        model.train()
        order = generator.permutation(len(train_set))
        total_loss = 0.0
        batches = 0
        for x, y in _batches(train_set, order, batch_size, augment=True, generator=generator):
            loss, grads = loss_and_grad(model, x, y)
            optimizer.update(model, grads)
            mx.eval(model.parameters(), optimizer.state, loss)
            total_loss += float(loss)
            batches += 1

        model.eval()
        val_accuracy = _accuracy(model, val_set, batch_size)
        train_accuracy = _accuracy(model, train_set, batch_size)
        if val_accuracy > best_accuracy:
            best_accuracy = val_accuracy
            best_epoch = epoch
            best_params = _copy_parameters(model.parameters())
            stale = 0
        else:
            stale += 1
        print(
            f"       epoch {epoch:02d}/{epochs}  loss={total_loss / max(batches, 1):.4f}"
            f"  train_acc={train_accuracy:.4f}  val_acc={val_accuracy:.4f}"
            f"  best={best_accuracy:.4f}@{best_epoch}",
            file=sys.stderr,
        )
        if stale >= patience and best_params is not None:
            print(f"       验证准确率 {patience} 轮未提升，提前停止", file=sys.stderr)
            break

    if best_params is not None:
        model.update(best_params)
    model.eval()
    mx.eval(model.parameters())
    return model, best_epoch, best_accuracy


def _copy_parameters(parameters: dict) -> dict:
    import copy

    return copy.deepcopy(parameters)


def _batches(
    image_set: ScreenImageSet,
    order: np.ndarray,
    batch_size: int,
    *,
    augment: bool,
    generator: np.random.Generator | None = None,
):
    for start in range(0, len(order), batch_size):
        chunk = order[start : start + batch_size]
        pixels = image_set.images[chunk].astype(np.float32) / 255.0
        if augment and generator is not None:
            # 屏幕整体亮度/对比度轻微扰动；不做水平翻转（左右面板/按钮不对称）。
            gain = generator.uniform(0.9, 1.1, size=(len(chunk), 1, 1, 1)).astype(
                np.float32
            )
            bias = generator.uniform(-0.05, 0.05, size=(len(chunk), 1, 1, 1)).astype(
                np.float32
            )
            pixels = np.clip(pixels * gain + bias, 0.0, 1.0)
        yield mx.array(pixels), mx.array(image_set.labels[chunk])


def _accuracy(model: ScreenNet, image_set: ScreenImageSet, batch_size: int) -> float:
    predictions = _predict(model, image_set, batch_size)[1]
    return float((predictions == image_set.labels).mean()) if len(image_set) else 0.0


def _predict(
    model: ScreenNet, image_set: ScreenImageSet, batch_size: int
) -> tuple[np.ndarray, np.ndarray]:
    model.eval()
    logits: list[np.ndarray] = []
    for start in range(0, len(image_set), batch_size):
        chunk = np.arange(start, min(start + batch_size, len(image_set)))
        pixels = mx.array(image_set.images[chunk].astype(np.float32) / 255.0)
        logits.append(np.asarray(model(pixels)))
    if not logits:
        return np.zeros((0,), np.int32), np.zeros((0,), np.int32)
    stacked = np.concatenate(logits, axis=0)
    return image_set.labels, stacked.argmax(axis=1).astype(np.int32)


def _class_weights(labels: np.ndarray, num_classes: int) -> np.ndarray:
    counts = np.bincount(labels, minlength=num_classes).astype(np.float64)
    present = counts > 0
    weights = np.ones(num_classes, dtype=np.float64)
    if present.any():
        weights[present] = counts[present].sum() / (present.sum() * counts[present])
    return np.clip(weights, 0.0, 10.0).astype(np.float32)


def _print_report(result: dict) -> None:
    metrics = result["metrics"]
    print(
        f"[wgai] screen: val_acc={metrics['valAccuracy']:.4f}"
        f"（{result['valImages']} 张，best epoch {result['bestEpoch']}/{result['epochs']}）"
    )
    print("       类别        支持   精确率  召回率   F1")
    for item in metrics["perClass"]:
        print(
            f"       {item['class']:<12}{item['support']:>5}"
            f"{item['precision']:>8.3f}{item['recall']:>8.3f}{item['f1']:>7.3f}"
        )
    if metrics["topConfusions"]:
        print("       主要混淆：")
        for item in metrics["topConfusions"][:5]:
            print(f"         {item['true']} → {item['predicted']}: {item['count']} 次")
    if result["testMetrics"]:
        test = result["testMetrics"]
        print(
            f"[wgai] screen: test_acc={test['accuracy']:.4f}"
            f"（{result['testImages']} 张）"
        )
        print("       类别        支持   精确率  召回率   F1")
        for item in test["perClass"]:
            print(
                f"       {item['class']:<12}{item['support']:>5}"
                f"{item['precision']:>8.3f}{item['recall']:>8.3f}{item['f1']:>7.3f}"
            )
        if test["topConfusions"]:
            print("       测试集混淆：")
            for item in test["topConfusions"][:5]:
                print(
                    f"         {item['true']} → {item['predicted']}: {item['count']} 次"
                )


# MARK: - Core ML 导出


class ScreenExportError(RuntimeError):
    """权重缺失或 Core ML 转换失败。"""


def export_screen_coreml(
    model_dir: Path,
    out_root: Path,
    *,
    dataset_root: Path | None = None,
) -> dict:
    model_dir = Path(model_dir).expanduser()
    out_root = Path(out_root).expanduser()
    package = out_root / "screen.mlpackage"
    info = _export_package(model_dir, package)
    if dataset_root is not None:
        info["agreement"] = verify_screen_coreml(
            package, Path(dataset_root).expanduser()
        )
    out_root.mkdir(parents=True, exist_ok=True)
    (out_root / "manifest.json").write_text(
        json.dumps(info, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return info


def _export_package(model_dir: Path, package_path: Path) -> dict:
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb

    config = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
    if config.get("architecture") != "screen-cnn-v1":
        raise ScreenExportError(f"不支持的屏幕分类器结构：{config.get('architecture')}")
    classes: list[str] = config["classes"]
    size = int(config["imageSize"])
    reduced = size // 16
    if reduced <= 0:
        raise ScreenExportError(f"图像尺寸异常：{size}")

    raw = mx.load(str(model_dir / "model.safetensors"))
    weights = {name: np.asarray(value) for name, value in raw.items()}
    blocks = [_conv_block_weights(weights, index) for index in range(1, 5)]

    @mb.program(
        input_specs=[mb.TensorSpec(shape=(1, 3, size, size))],
        opset_version=ct.target.iOS17,
    )
    def program(x):
        for conv_weight, conv_bias, mean, variance, gamma, beta in blocks:
            x = mb.conv(
                x=x, weight=conv_weight, bias=conv_bias, strides=[1, 1], pad_type="same"
            )
            x = mb.batch_norm(
                x=x,
                mean=mean,
                variance=variance,
                gamma=gamma,
                beta=beta,
                epsilon=1e-5,
            )
            x = mb.relu(x=x)
            x = mb.max_pool(
                x=x, kernel_sizes=[2, 2], strides=[2, 2], pad_type="valid"
            )
        # 全局平均池化：与训练端 nn.AvgPool2d(kernel_size=size//16) 对齐。
        x = mb.avg_pool(
            x=x,
            kernel_sizes=[reduced, reduced],
            strides=[reduced, reduced],
            pad_type="valid",
        )
        x = mb.reshape(x=x, shape=[1, 128])
        x = mb.linear(
            x=x,
            weight=weights["fc1.weight"].astype(np.float32),
            bias=weights["fc1.bias"].astype(np.float32),
        )
        x = mb.relu(x=x)
        x = mb.linear(
            x=x,
            weight=weights["fc2.weight"].astype(np.float32),
            bias=weights["fc2.bias"].astype(np.float32),
        )
        return mb.softmax(x=x, axis=-1)

    model = ct.convert(
        program,
        convert_to="mlprogram",
        inputs=[
            ct.ImageType(
                name="x",
                shape=(1, 3, size, size),
                scale=1.0 / 255.0,
                color_layout=ct.colorlayout.RGB,
            )
        ],
        classifier_config=ct.ClassifierConfig(classes),
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    model.short_description = "天天军棋·翻翻棋 7 类屏幕状态分类器"
    package_path.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(package_path))
    return {
        "task": "screen",
        "classes": classes,
        "imageSize": size,
        "package": str(package_path),
        "minimumDeploymentTarget": "iOS17",
    }


def verify_screen_coreml(
    package_path: Path,
    dataset_root: Path,
    *,
    split: str | None = None,
) -> dict:
    import coremltools as ct
    from PIL import Image

    package_path = Path(package_path)
    if package_path.is_dir() and package_path.suffix != ".mlpackage":
        package_path = package_path / "screen.mlpackage"
    model = ct.models.MLModel(str(package_path))
    rows = _read_rows(dataset_root)
    split = split or ("test" if any(row["split"] == "test" for row in rows) else "val")
    holdout = _load_images(dataset_root, rows, split, SCREEN_CLASSES, 192)
    if not len(holdout):
        if split == "test":
            return verify_screen_coreml(package_path, dataset_root, split="val")
        return {"split": split, "samples": 0, "accuracy": 0.0}

    hits = 0
    for index in range(len(holdout)):
        prediction = model.predict({"x": Image.fromarray(holdout.images[index])})
        label = prediction.get("classLabel")
        predicted = holdout.classes.index(label) if label in holdout.classes else -1
        hits += int(predicted == int(holdout.labels[index]))
        probs = prediction.get("classLabel_probs") or {}
        if not probs:
            raise ScreenExportError("screen: Core ML 输出缺少 classLabel_probs")
        if index == 0:
            values = [float(value) for value in probs.values()]
            total = sum(values)
            if abs(total - 1.0) > 0.01 or min(values) < -0.001:
                raise ScreenExportError(
                    f"screen: classLabel_probs 不是概率（sum={total:.3f}）"
                )
    return {
        "split": split,
        "samples": len(holdout),
        "accuracy": round(hits / len(holdout), 4),
    }


def _conv_block_weights(weights: dict[str, np.ndarray], index: int) -> tuple:
    prefix = f"block{index}"
    conv = weights[f"{prefix}.conv.weight"]
    return (
        conv.transpose(0, 3, 1, 2).astype(np.float32),
        weights[f"{prefix}.conv.bias"].astype(np.float32),
        weights[f"{prefix}.norm.running_mean"].astype(np.float32),
        weights[f"{prefix}.norm.running_var"].astype(np.float32),
        weights[f"{prefix}.norm.weight"].astype(np.float32),
        weights[f"{prefix}.norm.bias"].astype(np.float32),
    )
