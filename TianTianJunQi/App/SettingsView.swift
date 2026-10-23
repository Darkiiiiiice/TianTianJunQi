import SwiftUI

/// 设置页：权限 / 校准 / 棋盘配置 / 对手模式 / 模型路径的占位框架。
/// 各分区实际控制在对应任务接入：权限 M0-3、校准 M1-1、对手与棋盘随 P0 回填。
struct SettingsView: View {
    var body: some View {
        Form {
            Section("权限") {
                LabeledContent("屏幕录制", value: "未检查（M0-3 接入）")
                LabeledContent("辅助功能", value: "未检查（M0-3 接入）")
                LabeledContent("输入监控", value: "未检查（M0-3 接入）")
            }
            Section("校准") {
                LabeledContent("校准状态", value: "未校准（M1-1 接入向导）")
            }
            Section("棋盘配置") {
                LabeledContent("棋盘规格", value: "4 × 8（占位，以 P0-3 实测为准）")
            }
            Section("对手模式") {
                LabeledContent("默认对手", value: "人机练习（占位）")
                LabeledContent("真人匹配自动连开", value: "关闭（默认）")
            }
            Section("模型") {
                LabeledContent("当前模型", value: "无（M3-4 接入加载）")
                LabeledContent("模型目录", value: "~/Library/Application Support/TianTianJunqiAI/models")
            }
        }
        .formStyle(.grouped)
    }
}
