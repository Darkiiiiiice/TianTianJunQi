"""图像分类基线训练（M1-4）：state / color / piece 三个独立小 CNN。

输入是 `wgai.dataset` 导出的 board-classifier-v1：
- 图像已按内容哈希去重；
- train/val 按对局会话隔离，同一张图不会跨集。

输出 `<out>/<task>/`：
- `model.safetensors`：MLX 权重
- `config.json`：类别顺序、输入尺寸、归一化方式（Core ML 导出按此还原）
- `metrics.json`：准确率、混淆矩阵、逐类 precision/recall/F1/support

稀少类不合并，先看基线混淆矩阵再决定补样本。
"""

from __future__ import annotations

import csv
import copy
import json
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

from wgai.dataset import COLOR_CLASSES, PIECE_IDS, STATE_CLASSES

DEFAULT_IMAGE_SIZE = 128
DEFAULT_EPOCHS = 40
DEFAULT_BATCH_SIZE = 64
DEFAULT_LR = 1e-3
DEFAULT_SEED = 0
# 训练集唯一图少于此数的类别视为稀少类，指标里单独标注样本量风险。
RARE_CLASS_THRESHOLD = 30

TASK_CLASSES: dict[str, tuple[str, ...]] = {
    "state": STATE_CLASSES,
    "color": COLOR_CLASSES,
    "piece": tuple(PIECE_IDS.values()),
}
TASK_LABEL_COLUMN = {"state": "state", "color": "color", "piece": "piece_id"}
TASK_FILE_COLUMN = {
    "state": "state_file",
    "color": "color_file",
    "piece": "piece_file",
}


class TrainError(RuntimeError):
    """数据集不可用或训练配置非法。"""


@dataclass
class ImageSet:
    images: np.ndarray  # uint8, NHWC
    labels: np.ndarray  # int32，索引对应 `classes`
    classes: tuple[str, ...]

    def __len__(self) -> int:
        return int(self.labels.shape[0])

    def distribution(self) -> dict[str, int]:
        counts = np.bincount(self.labels, minlength=len(self.classes))
        return {name: int(counts[index]) for index, name in enumerate(self.classes)}


@dataclass
class TaskResult:
    task: str
    classes: tuple[str, ...]
    train_images: int
    val_images: int
    epochs: int
    best_epoch: int
    train_distribution: dict[str, int]
    val_distribution: dict[str, int]
    metrics: dict
    test_images: int = 0
    test_distribution: dict[str, int] = field(default_factory=dict)
    test_metrics: dict | None = None

    def as_dict(self) -> dict:
        return {
            "task": self.task,
            "classes": list(self.classes),
            "trainImages": self.train_images,
            "valImages": self.val_images,
            "testImages": self.test_images,
            "epochs": self.epochs,
            "bestEpoch": self.best_epoch,
            "trainDistribution": self.train_distribution,
            "valDistribution": self.val_distribution,
            "testDistribution": self.test_distribution,
            "testMetrics": self.test_metrics,
            **self.metrics,
        }


class ConvBlock(nn.Module):
    """conv → batchnorm → relu → maxpool。

    没有 BN 时，棋子任务（12 类细粒度汉字）在 40 轮内几乎不收敛；
    加 BN 后验证准确率可到 97%。
    """

    def __init__(self, in_channels: int, out_channels: int):
        super().__init__()
        self.conv = nn.Conv2d(in_channels, out_channels, 3, padding=1)
        self.norm = nn.BatchNorm(out_channels)
        self.pool = nn.MaxPool2d(2)

    def __call__(self, x: mx.array) -> mx.array:
        return self.pool(nn.relu(self.norm(self.conv(x))))


class CellClassifier(nn.Module):
    """4 层卷积 + 保留空间位置的全连接头，输入 NHWC 0–1 RGB。

    不做全局平均池化：棋子的类别信息主要在汉字笔画的空间结构上，
    空间平均会把笔画抹平（实测棋子任务只能到 12% 的随机水平）。
    """

    def __init__(self, num_classes: int, input_size: int = DEFAULT_IMAGE_SIZE):
        super().__init__()
        if input_size % 16:
            raise TrainError(f"图像尺寸需能被 16 整除，当前 {input_size}")
        self.block1 = ConvBlock(3, 32)
        self.block2 = ConvBlock(32, 64)
        self.block3 = ConvBlock(64, 128)
        self.block4 = ConvBlock(128, 128)
        reduced = input_size // 16
        self.fc1 = nn.Linear(128 * reduced * reduced, 256)
        self.dropout = nn.Dropout(0.1)
        self.fc2 = nn.Linear(256, num_classes)

    def __call__(self, x: mx.array) -> mx.array:
        x = self.block4(self.block3(self.block2(self.block1(x))))
        x = x.reshape(x.shape[0], -1)
        x = self.dropout(nn.relu(self.fc1(x)))
        return self.fc2(x)


def train_tasks(
    dataset_root: Path,
    out_root: Path,
    *,
    tasks: list[str] | None = None,
    epochs: int = DEFAULT_EPOCHS,
    batch_size: int = DEFAULT_BATCH_SIZE,
    learning_rate: float = DEFAULT_LR,
    image_size: int = DEFAULT_IMAGE_SIZE,
    seed: int = DEFAULT_SEED,
) -> dict[str, TaskResult]:
    """依次训练多个分类任务，把权重与指标写入 `out_root/<task>/`。"""
    dataset_root = Path(dataset_root)
    out_root = Path(out_root)
    if not (dataset_root / "labels.csv").is_file():
        raise TrainError(f"数据集缺少 labels.csv：{dataset_root}")

    selected = tasks or list(TASK_CLASSES)
    unknown = [task for task in selected if task not in TASK_CLASSES]
    if unknown:
        raise TrainError(f"未知任务 {unknown}；可选：{'、'.join(TASK_CLASSES)}")

    rows = _read_labels(dataset_root)
    results: dict[str, TaskResult] = {}
    for task in selected:
        classes = TASK_CLASSES[task]
        train_set = _load_images(
            dataset_root, rows, "train", task, classes, image_size
        )
        val_set = _load_images(dataset_root, rows, "val", task, classes, image_size)
        test_set = _load_images(dataset_root, rows, "test", task, classes, image_size)
        if not len(train_set):
            raise TrainError(f"任务 {task} 的 train 集为空")
        if not len(val_set):
            raise TrainError(f"任务 {task} 的 val 集为空：无法评估，请检查 split 设置")

        print(
            f"[wgai] {task}: train {len(train_set)} 张 / val {len(val_set)} 张"
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

        task_root = out_root / task
        task_root.mkdir(parents=True, exist_ok=True)
        mx.save_safetensors(
            str(task_root / "model.safetensors"),
            dict(tree_flatten(model.parameters())),
        )
        (task_root / "config.json").write_text(
            json.dumps(
                {
                    "task": task,
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
        result = TaskResult(
            task=task,
            classes=classes,
            train_images=len(train_set),
            val_images=len(val_set),
            epochs=epochs,
            best_epoch=best_epoch,
            train_distribution=train_set.distribution(),
            val_distribution=val_set.distribution(),
            metrics=metrics,
            test_images=len(test_set),
            test_distribution=test_set.distribution() if len(test_set) else {},
            test_metrics=test_metrics,
        )
        (task_root / "metrics.json").write_text(
            json.dumps(result.as_dict(), ensure_ascii=False, indent=2, sort_keys=True)
            + "\n",
            encoding="utf-8",
        )
        results[task] = result
        _print_report(result)

    out_root.mkdir(parents=True, exist_ok=True)
    (out_root / "baseline.json").write_text(
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
                "tasks": {task: result.as_dict() for task, result in results.items()},
            },
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    return results


def classification_metrics(
    y_true: np.ndarray, y_pred: np.ndarray, classes: tuple[str, ...]
) -> dict:
    """准确率 + 混淆矩阵（行=真值，列=预测）+ 逐类 P/R/F1。"""
    y_true = np.asarray(y_true, dtype=np.int64)
    y_pred = np.asarray(y_pred, dtype=np.int64)
    if len(y_true) != len(y_pred):
        raise ValueError("y_true 与 y_pred 长度不一致")
    count = len(classes)
    confusion = np.zeros((count, count), dtype=np.int64)
    for truth, pred in zip(y_true.tolist(), y_pred.tolist()):
        confusion[truth, pred] += 1

    total = int(confusion.sum())
    accuracy = float(np.trace(confusion) / total) if total else 0.0
    per_class = []
    for index, name in enumerate(classes):
        support = int(confusion[index].sum())
        predicted = int(confusion[:, index].sum())
        hits = int(confusion[index, index])
        precision = hits / predicted if predicted else 0.0
        recall = hits / support if support else 0.0
        f1 = (
            2 * precision * recall / (precision + recall)
            if precision + recall
            else 0.0
        )
        per_class.append(
            {
                "class": name,
                "support": support,
                "predicted": predicted,
                "precision": round(precision, 4),
                "recall": round(recall, 4),
                "f1": round(f1, 4),
            }
        )

    errors = [
        {
            "true": classes[truth],
            "predicted": classes[pred],
            "count": int(confusion[truth, pred]),
        }
        for truth in range(count)
        for pred in range(count)
        if truth != pred and confusion[truth, pred]
    ]
    errors.sort(key=lambda item: item["count"], reverse=True)

    return {
        "accuracy": round(accuracy, 4),
        "samples": total,
        "confusionMatrix": confusion.tolist(),
        "perClass": per_class,
        "topConfusions": errors[:20],
    }


def _read_labels(dataset_root: Path) -> list[dict[str, str]]:
    with (dataset_root / "labels.csv").open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise TrainError(f"labels.csv 为空：{dataset_root}")
    return rows


def _load_images(
    dataset_root: Path,
    rows: list[dict[str, str]],
    split: str,
    task: str,
    classes: tuple[str, ...],
    image_size: int,
) -> ImageSet:
    label_column = TASK_LABEL_COLUMN[task]
    file_column = TASK_FILE_COLUMN[task]
    class_index = {name: index for index, name in enumerate(classes)}

    arrays: list[np.ndarray] = []
    labels: list[int] = []
    for row in rows:
        if row["split"] != split:
            continue
        value = row[label_column]
        if value not in class_index or not row[file_column]:
            continue
        path = dataset_root / row[file_column]
        if not path.is_file():
            raise TrainError(f"缺少图像：{path}")
        with Image.open(path) as image:
            image = image.convert("RGB")
            if image.size != (image_size, image_size):
                image = image.resize((image_size, image_size), Image.BILINEAR)
            arrays.append(np.asarray(image, dtype=np.uint8))
        labels.append(class_index[value])

    if not arrays:
        return ImageSet(
            images=np.zeros((0, image_size, image_size, 3), dtype=np.uint8),
            labels=np.zeros((0,), dtype=np.int32),
            classes=classes,
        )
    return ImageSet(
        images=np.stack(arrays), labels=np.array(labels, dtype=np.int32), classes=classes
    )


def _fit(
    train_set: ImageSet,
    val_set: ImageSet,
    *,
    epochs: int,
    batch_size: int,
    learning_rate: float,
    seed: int,
) -> tuple[CellClassifier, int, float]:
    """训练并按验证准确率保留最佳权重；返回 (模型, 最佳轮次, 最佳准确率)。"""
    mx.random.seed(seed)
    generator = np.random.default_rng(seed)
    model = CellClassifier(len(train_set.classes), train_set.images.shape[1])
    optimizer = optim.AdamW(learning_rate=learning_rate, weight_decay=0.01)
    class_weights = mx.array(_class_weights(train_set.labels, len(train_set.classes)))

    def loss_fn(model: CellClassifier, x: mx.array, y: mx.array) -> mx.array:
        logits = model(x)
        log_probs = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
        picked = mx.take_along_axis(log_probs, y[:, None], axis=1).squeeze(-1)
        return -(picked * mx.take(class_weights, y)).mean()

    loss_and_grad = nn.value_and_grad(model, loss_fn)
    best_accuracy = -1.0
    best_epoch = 0
    best_params = copy.deepcopy(model.parameters())
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
            best_params = copy.deepcopy(model.parameters())
            stale = 0
        else:
            stale += 1
        print(
            f"       epoch {epoch:02d}/{epochs}  loss={total_loss / max(batches, 1):.4f}"
            f"  train_acc={train_accuracy:.4f}  val_acc={val_accuracy:.4f}"
            f"  best={best_accuracy:.4f}@{best_epoch}",
            file=sys.stderr,
        )
        if stale >= patience:
            print(f"       验证准确率 {patience} 轮未提升，提前停止", file=sys.stderr)
            break

    model.update(best_params)
    model.eval()
    mx.eval(model.parameters())
    return model, best_epoch, best_accuracy


def _batches(
    image_set: ImageSet,
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
            # 只做轻度光度扰动：棋盘图上下翻转会破坏棋子汉字，不做几何增强。
            gain = generator.uniform(0.9, 1.1, size=(len(chunk), 1, 1, 1)).astype(
                np.float32
            )
            bias = generator.uniform(-0.05, 0.05, size=(len(chunk), 1, 1, 1)).astype(
                np.float32
            )
            pixels = np.clip(pixels * gain + bias, 0.0, 1.0)
        yield mx.array(pixels), mx.array(image_set.labels[chunk])


def _accuracy(model: CellClassifier, image_set: ImageSet, batch_size: int) -> float:
    predictions = _predict(model, image_set, batch_size)[1]
    return float((predictions == image_set.labels).mean()) if len(image_set) else 0.0


def _predict(
    model: CellClassifier, image_set: ImageSet, batch_size: int
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
    """逆频率权重，缓解 empty/hidden 远多于 revealed 的失衡。"""
    counts = np.bincount(labels, minlength=num_classes).astype(np.float64)
    present = counts > 0
    weights = np.ones(num_classes, dtype=np.float64)
    if present.any():
        weights[present] = counts[present].sum() / (present.sum() * counts[present])
    return np.clip(weights, 0.0, 10.0).astype(np.float32)


def _print_report(result: TaskResult) -> None:
    metrics = result.metrics
    print(
        f"[wgai] {result.task}: val_acc={metrics['valAccuracy']:.4f}"
        f"（{result.val_images} 张，best epoch {result.best_epoch}/{result.epochs}）"
    )
    print("       类别        支持   精确率  召回率   F1")
    for item in metrics["perClass"]:
        flag = ""
        if result.train_distribution.get(item["class"], 0) < RARE_CLASS_THRESHOLD:
            flag = "  (稀少)"
        print(
            f"       {item['class']:<12}{item['support']:>5}"
            f"{item['precision']:>8.3f}{item['recall']:>8.3f}{item['f1']:>7.3f}{flag}"
        )
    if metrics["topConfusions"]:
        print("       主要混淆：")
        for item in metrics["topConfusions"][:5]:
            print(
                f"         {item['true']} → {item['predicted']}: {item['count']} 次"
            )
    if result.test_metrics:
        test = result.test_metrics
        print(
            f"[wgai] {result.task}: test_acc={test['accuracy']:.4f}"
            f"（{result.test_images} 张）"
        )
        print("       类别        支持   精确率  召回率   F1")
        for item in test["perClass"]:
            flag = ""
            if result.train_distribution.get(item["class"], 0) < RARE_CLASS_THRESHOLD:
                flag = "  (稀少)"
            print(
                f"       {item['class']:<12}{item['support']:>5}"
                f"{item['precision']:>8.3f}{item['recall']:>8.3f}{item['f1']:>7.3f}{flag}"
            )
        if test["topConfusions"]:
            print("       测试集混淆：")
            for item in test["topConfusions"][:5]:
                print(
                    f"         {item['true']} → {item['predicted']}: {item['count']} 次"
                )
