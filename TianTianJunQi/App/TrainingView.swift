import SwiftUI

/// 训练页：M0-9 推理 smoke test；TrainerBridge（Process + JSONL 进度）在 M4-1 接入。
struct TrainingView: View {
    @State private var report: PolicyKit.SmokeReport?
    @State private var errorMessage: String?
    @State private var running = false

    var body: some View {
        Form {
            Section {
                LabeledContent(
                    "流程",
                    value: "随机初始化 dummy 策略 → model.safetensors 落盘 → 重新加载 → 固定输入进程内前向"
                )
                Button(running ? "运行中…" : "运行推理 smoke test") {
                    runSmokeTest()
                }
                .disabled(running)

                if let report {
                    LabeledContent("policy 输出", value: "\(report.policyCount)（5 × 12 cells）")
                    LabeledContent("value 输出", value: "\(report.valueCount)")
                    LabeledContent("前向耗时", value: String(format: "%.1f ms", report.latencyMS))
                    LabeledContent("存取一致性", value: report.reloadConsistent ? "一致" : "不一致")
                    LabeledContent("dummy 模型目录", value: report.modelDirectory)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            } header: {
                Text("推理 smoke test（M0-9）")
            } footer: {
                Text("验证 MLX Swift 链路：safetensors 读写、模型重建、进程内推理。训练产物在 M3-4 按同一权重键名导出并加载。")
            }

            Section("训练") {
                LabeledContent("TrainerBridge", value: "未接入（M4-1 接入 Python 子进程）")
                LabeledContent("本地训练", value: "终端运行 make train 查看占位行为")
            }
        }
        .formStyle(.grouped)
    }

    private func runSmokeTest() {
        running = true
        errorMessage = nil
        report = nil
        Task {
            do {
                report = try PolicyKit.smokeTest()
            } catch {
                errorMessage = error.localizedDescription
            }
            running = false
        }
    }
}
