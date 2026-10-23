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

HELP_BY_COMMAND = {
    "train": "训练策略模型（M3 实现）",
    "eval": "模拟器/离线评测（M3 实现）",
    "export": "导出 safetensors + manifest（M3 实现）",
    "inspect": "检查 episode / 回放（M2 实现）",
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
    print(
        f"[wgai] `{args.command}` 尚未实现：按 docs/开发计划.md 对应里程碑落地。",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
