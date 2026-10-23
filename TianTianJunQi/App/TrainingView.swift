import SwiftUI

/// 训练页：占位；TrainerBridge（Process + JSONL 进度）在 M4-1 接入。
struct TrainingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("训练功能未接入", systemImage: "brain.head.profile")
        } description: {
            Text("训练由 Python MLX 子进程执行（M4-1 接入 TrainerBridge）。当前可在终端运行 make train 查看占位行为。")
        }
    }
}
