import SwiftUI

/// 设置页：权限 / 校准 / 棋盘配置 / 对手模式 / 模型路径。
/// 权限区为实时状态（M0-3）；校准 M1-1 接入向导；对手与棋盘随 P0 回填。
struct SettingsView: View {
    let permissions: PermissionStore

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases, id: \.rawValue) { kind in
                    permissionRow(kind)
                }
            } header: {
                Text("权限")
            } footer: {
                Text("权限不齐全时，后续步骤会以难以定位的方式失败。macOS 会周期性复查屏幕录制授权，客户端每 5 秒自动复查一次。输入监控仅在“录制人类示范”（M2-8）时需要：系统授权弹窗只在首次请求出现，若点“去授权”无反应，请点“打开设置”在列表中添加本应用并开启。")
            }
            Section("校准") {
                LabeledContent("校准状态", value: "未校准（M1-1 接入向导）")
            }
            Section("棋盘配置") {
                LabeledContent("棋盘规格", value: "5 × 12（P0-3 实测，30 枚/方）")
                LabeledContent("场次", value: "新手场（每局 50 金币）")
            }
            Section("对手模式") {
                LabeledContent("默认对手", value: "真人匹配（无单机模式）")
                LabeledContent("真人匹配自动连开", value: "开启（用户显式选择）")
                LabeledContent("匹配超时", value: "120 秒（超时暂停）")
            }
            Section("模型") {
                LabeledContent("当前模型", value: "无（M3-4 接入加载）")
                LabeledContent("模型目录", value: "~/Library/Application Support/TianTianJunqiAI/models")
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.label)
                Text(kind.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge(kind)

            if permissions.statuses[kind] != .granted {
                Button("去授权") { permissions.request(kind) }
                Button("打开设置") { permissions.openSettings(kind) }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(_ kind: PermissionKind) -> some View {
        switch permissions.statuses[kind] ?? .checking {
        case .granted:
            Text("已授权").foregroundStyle(.green)
        case .notGranted:
            Text("未授权").foregroundStyle(.orange)
        case .checking:
            Text("检查中").foregroundStyle(.secondary)
        }
    }
}
