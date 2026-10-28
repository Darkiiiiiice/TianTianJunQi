import AppKit
import SwiftUI

/// 设置页：权限 / 校准 / 棋盘配置 / 对手模式 / 模型路径。
/// 权限区为实时状态（M0-3）；校准区接入 M1-1 向导；对手与棋盘随 P0 回填。
struct SettingsView: View {
    let permissions: PermissionStore
    let calibration: CalibrationStore
    let windows: WindowMonitor
    let capture: CaptureService

    @State private var showCalibration = false
    @State private var showClearConfirm = false

    private let storage = StorageKit()

    private var profile: GameProfile {
        (try? storage.loadGameProfile()) ?? .tianTianJunQi
    }

    private var calibrationStatus: CalibrationStatus {
        calibration.status(
            currentWindowSize: windows.effectiveCandidate?.bounds.size,
            theme: profile.board.theme
        )
    }

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
            Section {
                LabeledContent("校准状态") {
                    calibrationBadge
                }
                if let calibration = calibration.calibration {
                    LabeledContent("窗口尺寸", value: "\(Int(calibration.windowSize.width))×\(Int(calibration.windowSize.height))")
                    LabeledContent("入口锚点", value: percentRect(calibration.modeEntry))
                    LabeledContent("棋盘四角", value: "\(calibration.boardCorners.count)/4")
                    if let venue = calibration.buttons["venue"] {
                        LabeledContent("场次锚点", value: percentRect(venue))
                    }
                }
                HStack(spacing: 10) {
                    Button("打开校准向导") { showCalibration = true }
                        .disabled(!permissions.controlReady || windows.effectiveWindowID == nil)
                    if calibration.calibration != nil {
                        Button("清除校准", role: .destructive) { showClearConfirm = true }
                    }
                }
                if let error = calibration.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("校准")
            } footer: {
                Text("在实时游戏画面上框选画布、棋盘四角、翻翻棋入口和新手场按钮。锚点按归一化坐标保存，窗口移动或缩放后仍可用；游戏皮肤变化后需要重新校准。")
            }
            Section("棋盘配置") {
                LabeledContent("棋盘规格", value: "5 × 12（25 枚/方 + 10 个空行营）")
                LabeledContent("场次", value: "新手场（每局 50 金币）")
            }
            Section("对手模式") {
                LabeledContent("默认对手", value: "真人匹配（无单机模式）")
                LabeledContent("真人匹配自动连开", value: "开启（用户显式选择）")
                LabeledContent("匹配超时", value: "120 秒（超时暂停）")
            }
            Section("模型") {
                LabeledContent("当前模型", value: "无（M3-4 接入加载）")
                LabeledContent("模型目录", value: displayPath(storage.modelsURL))
            }
            Section {
                LabeledContent("存储目录", value: displayPath(storage.rootURL))
                LabeledContent("游戏配置", value: "game-profile.json")
                LabeledContent(
                    "校准文件",
                    value: calibration.calibration == nil ? "calibration.json（未生成）" : "calibration.json"
                )
                Button("打开存储目录") {
                    NSWorkspace.shared.open(storage.rootURL)
                }
            } header: {
                Text("存储")
            } footer: {
                Text("episode、数据集、模型、日志全部放 Application Support（设计文档 §5），不进 App Bundle；校准文件只存本机，不入库。")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showCalibration) {
            CalibrationView(windows: windows, capture: capture, store: calibration)
        }
        .confirmationDialog("清除本机校准？", isPresented: $showClearConfirm) {
            Button("清除", role: .destructive) { calibration.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("入口/场次锚点会退回硬编码兜底，棋盘四角与画布区域将被删除。")
        }
    }

    @ViewBuilder
    private var calibrationBadge: some View {
        switch calibrationStatus {
        case .none:
            Text("未校准").foregroundStyle(.orange)
        case .ready:
            Text("已校准").foregroundStyle(.green)
        case .stale(let reason):
            Text("建议重新校准 · \(reason)").foregroundStyle(.orange)
        }
    }

    private func percentRect(_ rect: CGRect) -> String {
        "x \(Int(rect.minX * 100))% · y \(Int(rect.minY * 100))% · "
            + "\(Int(rect.width * 100))×\(Int(rect.height * 100))%"
    }

    /// 展示用路径：用户目录缩写为 `~`。
    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
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
