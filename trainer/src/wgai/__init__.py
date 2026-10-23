"""wgai：天天军棋·翻翻棋 AI 训练端。

模块划分见设计文档 §7.6：
- protocol    协议模型（GameState / Action / Episode）
- sim         翻翻棋规则引擎、模拟器、自博弈
- models      CNN/MLP、策略+价值头
- algorithms  行为克隆、DAgger、PPO/MCTS
- training    数据集、训练循环、指标、checkpoint
- export      safetensors + model.json + manifest
- eval        离线/模拟器评测（不提供运行时推理）

边界原则：Python 不 import Swift，Swift 不 import Python；
双方只通过 shared/schema、episode 文件、模型产物和 JSONL 进度通信。
"""

__version__ = "0.1.0"
