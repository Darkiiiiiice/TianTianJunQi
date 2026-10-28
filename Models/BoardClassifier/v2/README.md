# board-classifier-v2

M1-3/M1-4 的棋盘格子三分类器（state / color / piece）。

## 数据划分

- 数据集：`~/Library/Application Support/TianTianJunqiAI/datasets/board-classifier-v2`
- train：S0、S1、S2、S4、S6（1,511 张唯一图）
- val：S3（200 张；用于早停/选权重）
- test：S5（430 张；只在训练完成后评估一次）
- 去重：按格子图片 SHA-256；跨会话重复图归入 train，避免近邻泄漏。

## 指标

| task | val | test | test 张数 |
|---|---|---|---|
| state | 100% | 100% | 430 |
| color | 100% | 100% | 197（仅明子） |
| piece | 100% | 100% | 197（仅明子） |

注意：test 的明子只有 197 张，军旗 4 张（红 1、黑 3）、炸弹 12 张；这两个类的
100% 置信区间仍很宽，真机验收要继续看混淆矩阵/漏检。

## 产物

- `TianTianJunQi/Models/BoardClassifier/v2/*.mlpackage`：已加入 app target，
  Xcode 会编译成 app bundle 的 `state.mlmodelc` / `color.mlmodelc` / `piece.mlmodelc`。
- `manifest.json`：类别顺序、预处理、指标、SHA-256。
- `baseline.json`：MLX 训练端完整指标（含 testMetrics 与逐类混淆矩阵）。

## 复现

```sh
make train-classifier   # 训练到 board-classifier-v2/models/baseline
make export-coreml      # 导出 .mlpackage，并用 test 核对
make verify-models      # 只核对 Core ML 包
```

## 预处理

- 128×128 RGB，`scale = 1/255`，`inputLayout = NHWC`（Core ML 包内部为 NCHW）。
- 格子图必须与 `BoardSnapshotExporter` 的透视校正参数一致（`inset = 0.04`、
  `cellSize = 128`），否则会出现 train/serve 偏移。
- 置信度读 `classLabel_probs`：导出端已加 softmax（sum≈1）。不要用原始
  `linear_1` / logits；`make verify-models` 会校验概率是否归一化。
