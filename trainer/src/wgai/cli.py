"""wgai 命令行入口：train / eval / export / inspect。

各子命令按开发计划（docs/开发计划.md）落地：
- train   M3-2        行为克隆训练
- eval    M3-6        模拟器/离线评测
- export  M3-3        导出 safetensors + model.json + manifest
- inspect M2-6/M2-10  episode / 真实回放检查
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime
from pathlib import Path

HELP_BY_COMMAND = {
    "train": "训练棋盘格子分类器（state/color/piece，M1-4）",
    "eval": "模拟器/离线评测（M3 实现）",
    "export": "导出 safetensors + manifest（M3 实现）",
    "inspect": "检查 episode / 回放（M2 实现）",
    "dataset": "从样本库导出 Create ML 数据集（M1-3）",
    "coreml": "把基线模型导出为 Core ML（M1-5）",
    "verify": "核对 Core ML 包在 test/val 留出集上的准确率",
    "screen-dataset": "从屏幕样本导出 7 类数据集（M1-7）",
    "screen-train": "训练 7 类屏幕分类器（M1-7）",
    "screen-coreml": "把屏幕分类器导出为 Core ML（M1-7）",
    "screen-verify": "核对屏幕分类器 Core ML 包（M1-7）",
}


def _latest_dataset(root: Path) -> Path | None:
    """默认训练输入：datasets 目录下最新一份带 labels.csv 的数据集。"""
    if not root.is_dir():
        return None
    candidates = sorted(
        (path for path in root.iterdir() if (path / "labels.csv").is_file()),
        key=lambda path: path.name,
    )
    return candidates[-1] if candidates else None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="wgai",
        description="天天军棋·翻翻棋 AI 训练端（train / eval / export / inspect）",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    for command, help_text in HELP_BY_COMMAND.items():
        p = sub.add_parser(command, help=help_text)
        p.add_argument("--config", help="配置文件路径（yaml）")
        p.add_argument("--out", help="输出目录")
        p.add_argument("--input", help="输入路径（episode/数据集/模型）")
        if command == "train":
            p.add_argument(
                "--tasks",
                default="state,color,piece",
                help="逗号分隔的训练任务（默认 state,color,piece）",
            )
            p.add_argument("--epochs", type=int, default=None)
            p.add_argument("--batch-size", type=int, default=None)
            p.add_argument("--lr", type=float, default=None)
            p.add_argument("--image-size", type=int, default=None)
            p.add_argument("--seed", type=int, default=None)
        if command in ("coreml", "verify"):
            p.add_argument("--dataset", help="用于一致性核对的数据集目录")
        if command == "screen-dataset":
            p.add_argument(
                "--board-snapshots",
                help="可选：棋盘快照目录，把 frame.png 并入 board 类",
            )
            p.add_argument(
                "--gap-seconds",
                type=float,
                default=None,
                help="连拍 burst 切分阈值（秒，默认 3）",
            )
            p.add_argument(
                "--max-board",
                type=int,
                default=None,
                help="board 类最多使用多少张（默认 240，0 表示不限）",
            )
            p.add_argument("--seed", type=int, default=None)
        if command == "screen-train":
            p.add_argument("--epochs", type=int, default=None)
            p.add_argument("--batch-size", type=int, default=None)
            p.add_argument("--lr", type=float, default=None)
            p.add_argument("--image-size", type=int, default=None)
            p.add_argument("--seed", type=int, default=None)
        if command in ("screen-coreml", "screen-verify"):
            p.add_argument("--dataset", help="用于一致性核对的屏幕数据集目录")
        if command == "dataset":
            p.add_argument(
                "--val-session",
                help="指定验证会话（S0/S1… 或该会话的首/末快照目录名）",
            )
            p.add_argument(
                "--test-session",
                help="指定测试会话（S0/S1… 或该会话的首/末快照目录名）；指定后启用三路划分",
            )
            p.add_argument(
                "--gap-seconds",
                type=int,
                default=None,
                help="会话切分阈值：相邻快照间隔超过该秒数即视为新会话（默认 120）",
            )
    args = parser.parse_args(argv)

    if args.command == "train":
        from wgai.dataset import DEFAULT_DATASETS_ROOT
        from wgai.train import (
            DEFAULT_BATCH_SIZE,
            DEFAULT_EPOCHS,
            DEFAULT_IMAGE_SIZE,
            DEFAULT_LR,
            DEFAULT_SEED,
            TrainError,
            train_tasks,
        )

        dataset_root = (
            Path(args.input).expanduser()
            if args.input
            else _latest_dataset(DEFAULT_DATASETS_ROOT)
        )
        if dataset_root is None:
            print(
                "[wgai] 未找到数据集：请先运行 `wgai dataset`，或用 --input 指定目录",
                file=sys.stderr,
            )
            return 2
        out_root = (
            Path(args.out).expanduser()
            if args.out
            else dataset_root / "models" / "baseline"
        )
        tasks = [name.strip() for name in args.tasks.split(",") if name.strip()]
        try:
            results = train_tasks(
                dataset_root,
                out_root,
                tasks=tasks,
                epochs=args.epochs if args.epochs is not None else DEFAULT_EPOCHS,
                batch_size=(
                    args.batch_size
                    if args.batch_size is not None
                    else DEFAULT_BATCH_SIZE
                ),
                learning_rate=args.lr if args.lr is not None else DEFAULT_LR,
                image_size=(
                    args.image_size
                    if args.image_size is not None
                    else DEFAULT_IMAGE_SIZE
                ),
                seed=args.seed if args.seed is not None else DEFAULT_SEED,
            )
        except (TrainError, OSError) as error:
            print(f"[wgai] 训练失败：{error}", file=sys.stderr)
            return 2
        print(f"[wgai] 权重与指标已写入 {out_root}（{len(results)} 个任务）")
        return 0

    if args.command == "coreml":
        from wgai.coreml_export import CoreMLExportError, export_tasks
        from wgai.dataset import DEFAULT_DATASETS_ROOT

        dataset_root = (
            Path(args.dataset).expanduser()
            if args.dataset
            else _latest_dataset(DEFAULT_DATASETS_ROOT)
        )
        baseline_root = (
            Path(args.input).expanduser()
            if args.input
            else (dataset_root / "models" / "baseline" if dataset_root else None)
        )
        if baseline_root is None or not baseline_root.is_dir():
            print(
                "[wgai] 未找到训练产物：请先运行 `wgai train`，或用 --input 指定目录",
                file=sys.stderr,
            )
            return 2
        out_root = (
            Path(args.out).expanduser() if args.out else baseline_root / "coreml"
        )
        try:
            results = export_tasks(baseline_root, out_root, dataset_root=dataset_root)
        except (CoreMLExportError, OSError) as error:
            print(f"[wgai] Core ML 导出失败：{error}", file=sys.stderr)
            return 2
        for task, info in results.items():
            agreement = info.get("agreement") or {}
            print(
                f"[wgai] {task}: {info['package']}"
                f"（{len(info['classes'])} 类，Core ML {agreement.get('split', 'val')} "
                f"acc={agreement.get('accuracy', '—')}）"
            )
        return 0

    if args.command == "verify":
        from wgai.coreml_export import CoreMLExportError, verify_tasks
        from wgai.dataset import DEFAULT_DATASETS_ROOT

        dataset_root = (
            Path(args.dataset).expanduser()
            if args.dataset
            else _latest_dataset(DEFAULT_DATASETS_ROOT)
        )
        if dataset_root is None:
            print("[wgai] 未找到数据集：请用 --dataset 指定", file=sys.stderr)
            return 2
        packages_root = (
            Path(args.input).expanduser()
            if args.input
            else dataset_root / "models" / "baseline" / "coreml"
        )
        try:
            results = verify_tasks(packages_root, dataset_root)
        except (CoreMLExportError, OSError) as error:
            print(f"[wgai] Core ML 核对失败：{error}", file=sys.stderr)
            return 2
        for task, info in results.items():
            print(
                f"[wgai] {task}: {info['split']} acc={info['accuracy']:.4f}"
                f"（{info['samples']} 张）"
            )
        return 0

    if args.command == "screen-dataset":
        from wgai.screen import (
            BURST_GAP_SECONDS,
            DEFAULT_BOARD_SAMPLES_ROOT,
            DEFAULT_MAX_BOARD_SAMPLES,
            DEFAULT_SCREEN_DATASETS_ROOT,
            DEFAULT_SCREEN_SAMPLES_ROOT,
            DEFAULT_SEED,
            ScreenDatasetError,
            export_screen_dataset,
        )

        samples_root = (
            Path(args.input).expanduser() if args.input else DEFAULT_SCREEN_SAMPLES_ROOT
        )
        out_root = (
            Path(args.out).expanduser()
            if args.out
            else DEFAULT_SCREEN_DATASETS_ROOT / f"screen-classifier-{datetime.now():%Y%m%d-%H%M%S}"
        )
        board_root = (
            Path(args.board_snapshots).expanduser()
            if args.board_snapshots
            else DEFAULT_BOARD_SAMPLES_ROOT
        )
        if args.board_snapshots == "":
            board_root = None
        try:
            summary = export_screen_dataset(
                samples_root,
                out_root,
                board_snapshots_root=board_root,
                burst_gap_seconds=(
                    args.gap_seconds if args.gap_seconds is not None else BURST_GAP_SECONDS
                ),
                max_board_samples=(
                    args.max_board
                    if args.max_board is not None
                    else DEFAULT_MAX_BOARD_SAMPLES
                ),
                seed=args.seed if args.seed is not None else DEFAULT_SEED,
            )
        except (ScreenDatasetError, OSError) as error:
            print(f"[wgai] 屏幕数据集导出失败：{error}", file=sys.stderr)
            return 2
        print(
            f"[wgai] 已导出 {summary.unique_images} 张屏幕样本 → {summary.out}"
        )
        for split, counts in summary.splits.items():
            print(
                f"       {split}: "
                + " ".join(f"{name}={count}" for name, count in counts.items())
            )
        if summary.warnings:
            print(f"       警告 {len(summary.warnings)} 条，见 manifest.json", file=sys.stderr)
        return 0

    if args.command == "screen-train":
        from wgai.screen import (
            DEFAULT_BATCH_SIZE,
            DEFAULT_EPOCHS,
            DEFAULT_IMAGE_SIZE,
            DEFAULT_LR,
            DEFAULT_SCREEN_DATASETS_ROOT,
            DEFAULT_SEED,
            ScreenTrainError,
            train_screen,
        )

        dataset_root = (
            Path(args.input).expanduser()
            if args.input
            else _latest_dataset(DEFAULT_SCREEN_DATASETS_ROOT)
        )
        if dataset_root is None:
            print(
                "[wgai] 未找到屏幕数据集：请先运行 `wgai screen-dataset`，或用 --input 指定",
                file=sys.stderr,
            )
            return 2
        out_root = (
            Path(args.out).expanduser()
            if args.out
            else dataset_root / "models" / "baseline"
        )
        try:
            train_screen(
                dataset_root,
                out_root,
                epochs=args.epochs if args.epochs is not None else DEFAULT_EPOCHS,
                batch_size=(
                    args.batch_size if args.batch_size is not None else DEFAULT_BATCH_SIZE
                ),
                learning_rate=args.lr if args.lr is not None else DEFAULT_LR,
                image_size=(
                    args.image_size if args.image_size is not None else DEFAULT_IMAGE_SIZE
                ),
                seed=args.seed if args.seed is not None else DEFAULT_SEED,
            )
        except (ScreenTrainError, OSError) as error:
            print(f"[wgai] 屏幕分类器训练失败：{error}", file=sys.stderr)
            return 2
        print(f"[wgai] 屏幕分类器权重与指标已写入 {out_root}")
        return 0

    if args.command == "screen-coreml":
        from wgai.screen import (
            DEFAULT_SCREEN_DATASETS_ROOT,
            ScreenExportError,
            export_screen_coreml,
        )

        dataset_root = (
            Path(args.dataset).expanduser()
            if args.dataset
            else _latest_dataset(DEFAULT_SCREEN_DATASETS_ROOT)
        )
        model_dir = (
            Path(args.input).expanduser()
            if args.input
            else (dataset_root / "models" / "baseline" if dataset_root else None)
        )
        if model_dir is None or not model_dir.is_dir():
            print(
                "[wgai] 未找到屏幕分类器训练产物：请先运行 `wgai screen-train`，或用 --input 指定",
                file=sys.stderr,
            )
            return 2
        out_root = (
            Path(args.out).expanduser() if args.out else model_dir / "coreml"
        )
        try:
            info = export_screen_coreml(
                model_dir, out_root, dataset_root=dataset_root
            )
        except (ScreenExportError, OSError) as error:
            print(f"[wgai] 屏幕分类器 Core ML 导出失败：{error}", file=sys.stderr)
            return 2
        agreement = info.get("agreement") or {}
        print(
            f"[wgai] screen: {info['package']}"
            f"（{len(info['classes'])} 类，Core ML {agreement.get('split', 'val')} "
            f"acc={agreement.get('accuracy', '—')}）"
        )
        return 0

    if args.command == "screen-verify":
        from wgai.screen import (
            DEFAULT_SCREEN_DATASETS_ROOT,
            ScreenExportError,
            verify_screen_coreml,
        )

        dataset_root = (
            Path(args.dataset).expanduser()
            if args.dataset
            else _latest_dataset(DEFAULT_SCREEN_DATASETS_ROOT)
        )
        if dataset_root is None:
            print("[wgai] 未找到屏幕数据集：请用 --dataset 指定", file=sys.stderr)
            return 2
        package = (
            Path(args.input).expanduser()
            if args.input
            else dataset_root / "models" / "baseline" / "coreml" / "screen.mlpackage"
        )
        try:
            info = verify_screen_coreml(package, dataset_root)
        except (ScreenExportError, OSError) as error:
            print(f"[wgai] 屏幕分类器 Core ML 核对失败：{error}", file=sys.stderr)
            return 2
        print(
            f"[wgai] screen: {info['split']} acc={info['accuracy']:.4f}"
            f"（{info['samples']} 张）"
        )
        return 0

    if args.command == "dataset":
        from wgai.dataset import (
            DEFAULT_DATASETS_ROOT,
            DEFAULT_SAMPLES_ROOT,
            SESSION_GAP_SECONDS,
            DatasetExportError,
            export_samples,
        )

        samples_root = (
            Path(args.input).expanduser() if args.input else DEFAULT_SAMPLES_ROOT
        )
        out_root = (
            Path(args.out).expanduser()
            if args.out
            else DEFAULT_DATASETS_ROOT / f"board-classifier-{datetime.now():%Y%m%d-%H%M%S}"
        )
        try:
            summary = export_samples(
                samples_root,
                out_root,
                session_gap_seconds=(
                    args.gap_seconds if args.gap_seconds is not None else SESSION_GAP_SECONDS
                ),
                val_session=args.val_session,
                test_session=args.test_session,
            )
        except (DatasetExportError, OSError) as error:
            print(f"[wgai] 数据集导出失败：{error}", file=sys.stderr)
            return 2
        print(
            f"[wgai] 已导出 {summary.images} 张唯一图（原始 {summary.cells} 格 / "
            f"{summary.snapshots} 份快照）→ {summary.out}"
        )
        for name, stats in summary.splits.items():
            session_names = "、".join(
                session.name for session in summary.sessions if session.split == name
            )
            print(
                f"       {name}: {stats.images} 张（会话 {session_names or '—'}）"
                f" 状态 "
                + " ".join(f"{key}={value}" for key, value in stats.state_counts.items())
            )
        print(
            "       去重后棋子："
            + " ".join(
                f"{name}={count}"
                for name, count in summary.piece_counts.items()
                if count
            )
        )
        if summary.leaked_images:
            print(f"       跨会话重复图 {summary.leaked_images} 张，已归入 train")
        if summary.warnings:
            print(f"       跳过/警告 {len(summary.warnings)} 条，见 manifest.json", file=sys.stderr)
        return 0

    print(
        f"[wgai] `{args.command}` 尚未实现：按 docs/开发计划.md 对应里程碑落地。",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
