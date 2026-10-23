import SwiftUI

/// 概览页：运行状态摘要 + 操作按钮 + 竖屏克隆画面占位（M0-11 接入 SCStream 实时帧）。
struct OverviewView: View {
    let store: AppStateStore
    let permissions: PermissionStore

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 24) {
                statusSection
                actionSection
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            cloneSection
        }
        .padding()
    }

    private var statusSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("运行状态").foregroundStyle(.secondary)
                Text(store.state.label).font(.title3.bold())
            }
            GridRow {
                Text("游戏窗口").foregroundStyle(.secondary)
                Text("未检测").foregroundStyle(.secondary)
            }
            GridRow {
                Text("主界面").foregroundStyle(.secondary)
                Text("未识别").foregroundStyle(.secondary)
            }
            GridRow {
                Text("模式 / 对手").foregroundStyle(.secondary)
                Text("翻翻棋 · 人机练习（占位）")
            }
            GridRow {
                Text("模型").foregroundStyle(.secondary)
                Text("无（M3-4 接入）").foregroundStyle(.secondary)
            }
            GridRow {
                Text("权限").foregroundStyle(.secondary)
                if permissions.allGranted {
                    Text("已就绪（\(permissions.grantedCount)/\(PermissionKind.allCases.count)）")
                        .foregroundStyle(.green)
                } else {
                    Text("缺 \(permissions.missing.map(\.label).joined(separator: "、"))")
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("进入翻翻棋") {}
                Button("自动对局") {}
                Button("暂停") {}
                Button("急停", role: .destructive) {}
            }
            .buttonStyle(.bordered)
            .disabled(true)

            Text("按钮将在 RuntimeKit 接入后启用（M0-4 起）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cloneSection: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("竖屏克隆画面")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 220, height: 380)

            Text("M0-11 接入 SCStream 实时帧（只读）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
