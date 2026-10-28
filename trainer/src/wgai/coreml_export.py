"""把 MLX 训练的格子分类器导出为 Core ML（M1-5）。

三个任务各导出一个 `.mlpackage`：
- 输入：128×128 RGB 图像（Core ML `ImageType`，scale=1/255，客户端可直接喂 CVPixelBuffer）
- 输出：`classLabel` + `classProbability`（classifier 头，Vision/CoreML 直接可用）

权重直接读 `models/<task>/model.safetensors`，不依赖 PyTorch：
用 MIL ProgramBuilder 逐算子还原 `CellClassifier`（conv → BN → relu → pool → flatten → fc）。
"""

from __future__ import annotations

import json
from pathlib import Path

import mlx.core as mx
import numpy as np

from wgai.dataset import COLOR_CLASSES, PIECE_IDS, STATE_CLASSES
from wgai.train import _load_images, _read_labels

TASK_CLASSES: dict[str, tuple[str, ...]] = {
    "state": STATE_CLASSES,
    "color": COLOR_CLASSES,
    "piece": tuple(PIECE_IDS.values()),
}
BATCH_NORM_EPSILON = 1e-5
MIN_IOS_TARGET = "iOS17"


class CoreMLExportError(RuntimeError):
    """权重缺失或转换失败。"""


def export_tasks(
    baseline_root: Path,
    out_root: Path,
    *,
    dataset_root: Path | None = None,
) -> dict[str, dict]:
    """导出 baseline_root 下的全部任务，并在有数据集时核对与 MLX 的一致性。"""
    baseline_root = Path(baseline_root)
    out_root = Path(out_root)
    task_dirs = sorted(
        path for path in baseline_root.iterdir() if (path / "model.safetensors").is_file()
    )
    if not task_dirs:
        raise CoreMLExportError(f"{baseline_root} 下没有 model.safetensors")

    results: dict[str, dict] = {}
    for task_dir in task_dirs:
        task = task_dir.name
        package = out_root / f"{task}.mlpackage"
        info = export_task(task_dir, package)
        if dataset_root is not None and task in TASK_CLASSES:
            info["agreement"] = verify_task(package, task, Path(dataset_root))
        results[task] = info

    out_root.mkdir(parents=True, exist_ok=True)
    (out_root / "manifest.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return results


def export_task(task_dir: Path, package_path: Path) -> dict:
    """把一个任务的 safetensors 权重转成 Core ML classifier。"""
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb

    task_dir = Path(task_dir)
    config = json.loads((task_dir / "config.json").read_text(encoding="utf-8"))
    classes: list[str] = config["classes"]
    size = int(config["imageSize"])
    reduced = size // 16
    if reduced <= 0:
        raise CoreMLExportError(f"图像尺寸异常：{size}")

    raw = mx.load(str(task_dir / "model.safetensors"))
    weights = {name: np.asarray(value) for name, value in raw.items()}
    blocks = [
        _conv_block_weights(weights, index) for index in range(1, 5)
    ]
    flatten = 128 * reduced * reduced
    fc1_weight = _flatten_weight(weights["fc1.weight"], reduced, 128)
    if fc1_weight.shape[1] != flatten:
        raise CoreMLExportError(
            f"fc1 权重维度 {fc1_weight.shape} 与图像尺寸 {size} 不匹配"
        )

    @mb.program(
        input_specs=[mb.TensorSpec(shape=(1, 3, size, size))],
        opset_version=ct.target.iOS17,
    )
    def program(x):
        for conv_weight, conv_bias, mean, variance, gamma, beta in blocks:
            x = mb.conv(x=x, weight=conv_weight, bias=conv_bias, strides=[1, 1], pad_type="same")
            x = mb.batch_norm(
                x=x, mean=mean, variance=variance, gamma=gamma, beta=beta,
                epsilon=BATCH_NORM_EPSILON,
            )
            x = mb.relu(x=x)
            x = mb.max_pool(x=x, kernel_sizes=[2, 2], strides=[2, 2], pad_type="valid")
        x = mb.reshape(x=x, shape=[1, flatten])
        x = mb.linear(x=x, weight=fc1_weight, bias=weights["fc1.bias"].astype(np.float32))
        x = mb.relu(x=x)
        x = mb.linear(x=x, weight=weights["fc2.weight"].astype(np.float32), bias=weights["fc2.bias"].astype(np.float32))
        # Core ML 的 classLabel_probs 不会自动 softmax；不显式归一化会输出原始 logits，
        # 客户端拿它当置信度会得到 >1 / 负值。
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
    model.short_description = f"天天军棋·翻翻棋 {config.get('task', task_dir.name)} 分类器"
    package_path = Path(package_path)
    package_path.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(package_path))
    return {
        "task": config.get("task", task_dir.name),
        "classes": classes,
        "imageSize": size,
        "package": str(package_path),
        "minimumDeploymentTarget": MIN_IOS_TARGET,
    }


def verify_tasks(packages_root: Path, dataset_root: Path) -> dict[str, dict]:
    """核对目录下全部 Core ML 包在留出集（优先 test）上的准确率。"""
    packages_root = Path(packages_root)
    dataset_root = Path(dataset_root)
    results: dict[str, dict] = {}
    for package in sorted(packages_root.glob("*.mlpackage")):
        task = package.stem
        if task not in TASK_CLASSES:
            continue
        results[task] = verify_task(package, task, dataset_root)
    if not results:
        raise CoreMLExportError(f"{packages_root} 下没有可核对的 .mlpackage")
    return results


def _preferred_split(dataset_root: Path) -> str:
    """有 test 集就用 test，否则退回 val。"""
    rows = _read_labels(dataset_root)
    return "test" if any(row.get("split") == "test" for row in rows) else "val"


def verify_task(
    package_path: Path,
    task: str,
    dataset_root: Path,
    *,
    split: str | None = None,
) -> dict:
    """在留出集图像上跑 Core ML，核对导出模型与训练指标是否一致。"""
    import coremltools as ct
    from PIL import Image

    from wgai.train import TASK_CLASSES as TRAIN_TASK_CLASSES

    model = ct.models.MLModel(str(package_path))
    rows = _read_labels(dataset_root)
    split = split or _preferred_split(dataset_root)
    holdout = _load_images(
        dataset_root, rows, split, task, TRAIN_TASK_CLASSES[task], 128
    )
    if not len(holdout):
        if split == "test":
            return verify_task(package_path, task, dataset_root, split="val")
        return {"split": split, "samples": 0, "accuracy": 0.0}

    hits = 0
    for index in range(len(holdout)):
        prediction = model.predict({"x": Image.fromarray(holdout.images[index])})
        label = prediction.get("classLabel")
        predicted = holdout.classes.index(label) if label in holdout.classes else -1
        hits += int(predicted == int(holdout.labels[index]))

        # 置信度契约：classLabel_probs 必须是归一化概率，而不是原始 logits。
        probs = prediction.get("classLabel_probs") or {}
        if not probs:
            raise CoreMLExportError(f"{task}: Core ML 输出缺少 classLabel_probs")
        if index == 0:
            values = [float(value) for value in probs.values()]
            total = sum(values)
            if abs(total - 1.0) > 0.01 or min(values) < -0.001:
                raise CoreMLExportError(
                    f"{task}: classLabel_probs 不是概率（sum={total:.3f}）；"
                    "导出端需要在分类头后加 softmax"
                )
    return {
        "split": split,
        "samples": len(holdout),
        "accuracy": round(hits / len(holdout), 4),
    }


def _conv_block_weights(weights: dict[str, np.ndarray], index: int) -> tuple:
    """MLX 卷积权重 (O, kH, kW, I) → MIL (O, I, kH, kW)。"""
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


def _flatten_weight(weight: np.ndarray, reduced: int, channels: int) -> np.ndarray:
    """MLX 的 NHWC 展平顺序 (h, w, c) → MIL 的 NCHW 展平顺序 (c, h, w)。"""
    return (
        weight.reshape(weight.shape[0], reduced, reduced, channels)
        .transpose(0, 3, 1, 2)
        .reshape(weight.shape[0], -1)
        .astype(np.float32)
    )
