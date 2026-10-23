# 天天军棋·翻翻棋 AI — 顶层工作流（设计文档 §7.7 / 开发计划 M0-1）

TRAINER := trainer
APP_PROJECT := TianTianJunQi.xcodeproj

.DEFAULT_GOAL := help

.PHONY: bootstrap record train export eval play test clean help

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

play: ## 打开 Swift 客户端
	open $(APP_PROJECT)

test: ## Python 单测（Swift 单测待测试 target 建立后接入）
	cd $(TRAINER) && uv run pytest -q

clean: ## 清理 Python 缓存
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
	rm -rf $(TRAINER)/.pytest_cache

help: ## 显示各目标说明
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
