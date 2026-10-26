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
    "train": "训练策略模型（M3 实现）",
    "eval": "模拟器/离线评测（M3 实现）",
    "export": "导出 safetensors + manifest（M3 实现）",
    "inspect": "检查 episode / 回放（M2 实现）",
    "dataset": "从样本库导出 Create ML 数据集（M1-3）",
}


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
    args = parser.parse_args(argv)

    if args.command == "dataset":
        from wgai.dataset import (
            DEFAULT_DATASETS_ROOT,
            DEFAULT_SAMPLES_ROOT,
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
            summary = export_samples(samples_root, out_root)
        except (DatasetExportError, OSError) as error:
            print(f"[wgai] 数据集导出失败：{error}", file=sys.stderr)
            return 2
        print(
            f"[wgai] 已导出 {summary.cells} 格 / {summary.snapshots} 份快照 → {summary.out}"
        )
        print(
            "       状态："
            + " ".join(f"{name}={count}" for name, count in summary.state_counts.items())
        )
        print(
            "       颜色："
            + " ".join(f"{name}={count}" for name, count in summary.color_counts.items())
            + " · 棋子："
            + " ".join(
                f"{name}={count}"
                for name, count in summary.piece_counts.items()
                if count
            )
        )
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
