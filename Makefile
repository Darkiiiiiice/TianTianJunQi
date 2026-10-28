# 天天军棋·翻翻棋 AI — 顶层工作流（设计文档 §7.7 / 开发计划 M0-1）

TRAINER := trainer
APP_PROJECT := TianTianJunQi.xcodeproj
BOARD_DATASET ?= $(HOME)/Library/Application Support/TianTianJunqiAI/datasets/board-classifier-v2
BASELINE ?= $(BOARD_DATASET)/models/baseline
BOARD_SAMPLES ?= $(HOME)/Library/Application Support/TianTianJunqiAI/perception/samples
SCREEN_SAMPLES ?= $(HOME)/Library/Application Support/TianTianJunqiAI/perception/screen-samples
SCREEN_DATASET ?= $(HOME)/Library/Application Support/TianTianJunqiAI/datasets/screen-classifier-v1
SCREEN_MODEL ?= $(SCREEN_DATASET)/models/baseline

.DEFAULT_GOAL := help

.PHONY: bootstrap record train export eval play dataset train-classifier export-coreml verify-models screen-dataset screen-train export-screen verify-screen test test-python test-swift perf clean help

bootstrap: ## 初始化环境：uv sync + 校验 Xcode 工程
	cd $(TRAINER) && uv sync
	xcodebuild -project $(APP_PROJECT) -list

record: ## 打开客户端（录制模式 M2-8 接入）
	open $(APP_PROJECT)

train: ## 训练（占位；M3 接入 --config configs/bc.yaml --out models/<version>）
	cd $(TRAINER) && uv run wgai train

export: ## 导出模型（占位；M3 实现：safetensors + model.json + manifest）
	cd $(TRAINER) && uv run wgai export

eval: ## 模拟器/离线评测（占位；M3 实现）
	cd $(TRAINER) && uv run wgai eval

dataset: ## 从样本库 labels.json 导出 Create ML 分层数据集（M1-3）
	cd $(TRAINER) && uv run wgai dataset $(DATASET_ARGS)

train-classifier: ## 训练 state/color/piece 三个分类器（BOARD_DATASET / BASELINE 可覆盖）
	cd $(TRAINER) && uv run wgai train --input "$(BOARD_DATASET)" --out "$(BASELINE)"

export-coreml: ## 导出三个 Core ML 包，并用 test（没有则 val）核对
	cd $(TRAINER) && uv run wgai coreml --dataset "$(BOARD_DATASET)" --input "$(BASELINE)" --out "$(BASELINE)/coreml"

verify-models: ## 用 test（没有则 val）核对 Core ML 包
	cd $(TRAINER) && uv run wgai verify --dataset "$(BOARD_DATASET)" --input "$(BASELINE)/coreml"

screen-dataset: ## 从屏幕样本导出 7 类数据集（默认并入棋盘快照的 board 类）
	cd $(TRAINER) && uv run wgai screen-dataset --input "$(SCREEN_SAMPLES)" --board-snapshots "$(BOARD_SAMPLES)" --out "$(SCREEN_DATASET)"

screen-train: ## 训练 7 类屏幕分类器
	cd $(TRAINER) && uv run wgai screen-train --input "$(SCREEN_DATASET)" --out "$(SCREEN_MODEL)"

export-screen: ## 导出 screen.mlpackage 并核对留出集
	cd $(TRAINER) && uv run wgai screen-coreml --dataset "$(SCREEN_DATASET)" --input "$(SCREEN_MODEL)" --out "$(SCREEN_MODEL)/coreml"

verify-screen: ## 核对屏幕分类器 Core ML 包
	cd $(TRAINER) && uv run wgai screen-verify --dataset "$(SCREEN_DATASET)" --input "$(SCREEN_MODEL)/coreml/screen.mlpackage"

play: ## 打开 Swift 客户端
	open $(APP_PROJECT)

test: test-python test-swift ## 全部单测（Python + Swift 感知内核）

test-python: ## Python 单测
	cd $(TRAINER) && uv run pytest -q

test-swift: ## Swift 感知内核单测（BoardGeometry / BoardStabilizer）
	./scripts/run-swift-tests.sh

perf: ## M1-9 离线回放基准：感知 → 动作端到端延迟（PERF_BOARDS / PERF_SCREENS 可覆盖）
	./scripts/run-perf-bench.sh $(PERF_ARGS)

clean: ## 清理 Python 缓存
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
	rm -rf $(TRAINER)/.pytest_cache

help: ## 显示各目标说明
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
