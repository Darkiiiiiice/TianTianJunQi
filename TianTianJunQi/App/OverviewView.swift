import CoreImage
import CoreVideo
import SwiftUI

/// 概览页：运行状态摘要 + 操作按钮 + 实时画面（M0-5 最小观察器，M0-11 升级为竖屏克隆）。
struct OverviewView: View {
    let store: AppStateStore
    let permissions: PermissionStore
    let windows: WindowMonitor
    let capture: CaptureService
    let screenState: ScreenStateService
    let onEnterMode: () -> Void

    @State private var ciContext = CIContext()
    /// M0-11：竖屏旋转开关（显示层变换，不影响感知/注入坐标链）。
    @State private var portraitRotation = false

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 24) {
                statusSection
                actionSection
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            liveSection
        }
        .padding()
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("运行状态").foregroundStyle(.secondary)
                    Text(store.state.label).font(.title3.bold())
                }
            GridRow {
                Text("游戏窗口").foregroundStyle(.secondary)
                windowStatusText
            }
            GridRow {
                Text("主界面").foregroundStyle(.secondary)
                switch screenState.state {
                case .main: Text("主菜单 · 入口已定位").foregroundStyle(.green)
                case .board: Text("牌局")
                case .unknown: Text("未识别（OCR 运行中）").foregroundStyle(.secondary)
                }
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

            windowPicker
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 手动选择窗口：自动发现失败时的兜底（可从所有 layer-0 窗口中指定）。
    private var windowPicker: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(windows.allWindows) { candidate in
                    Button(candidateLabel(candidate)) {
                        windows.selectedWindowID = candidate.id
                    }
                }
                if windows.selectedWindowID != nil {
                    Divider()
                    Button("恢复自动选择") { windows.selectedWindowID = nil }
                }
            } label: {
                Label("手动选择窗口", systemImage: "scope")
            }
            .disabled(windows.allWindows.isEmpty)

            if windows.selectedWindowID != nil {
                Text("手动指定")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func candidateLabel(_ candidate: GameWindowCandidate) -> String {
        let title = candidate.title.isEmpty ? "无标题" : candidate.title
        let size = "\(Int(candidate.bounds.width))×\(Int(candidate.bounds.height))"
        return "\(title) · \(size) · \(candidate.bundleID)"
    }

    private var windowStatusText: Text {
        if !permissions.allGranted {
            return Text("待权限就绪").foregroundStyle(.secondary)
        }
        if !windows.isWeChatRunning {
            return Text("微信未运行").foregroundStyle(.orange)
        }
        if let target = windows.effectiveCandidate {
            return Text(target.title.isEmpty ? "已检测" : "已检测 · \(target.title)")
                .foregroundStyle(.green)
        }
        if windows.candidates.isEmpty {
            return Text("未检测到微信窗口").foregroundStyle(.orange)
        }
        return Text("未找到游戏窗口（\(windows.candidates.count) 个微信窗口）").foregroundStyle(.orange)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("进入翻翻棋") { onEnterMode() }
                    .disabled(!permissions.allGranted || windows.effectiveWindowID == nil)
                Button("自动对局") {}
                Button("暂停") {}
                Button("急停", role: .destructive) {}
            }
            .buttonStyle(.bordered)

            Text("自动对局/暂停/急停在 Session 闭环接入后启用；进入流程为单次点击验证（M0-8 接入步骤引擎）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 实时画面：读取 latestFrame，@Observable 驱动按帧刷新。
    private var liveSection: some View {
        VStack(spacing: 8) {
            Group {
                if let frame = capture.latestFrame,
                   let image = frameImage(frame, rotated: portraitRotation) {
                    Image(decorative: image, scale: frame.scale, orientation: .up)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.secondary)
                                Text("游戏画面预览")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            }
            .frame(width: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                Toggle("竖屏旋转", isOn: $portraitRotation)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                Text(portraitRotation ? "竖屏 · 文字侧躺" : "横版 · 原始画面")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = capture.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: 240)
            } else {
                Text(capture.isCapturing ? "实时画面 · 15fps" : "等待游戏窗口…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func frameImage(_ frame: CapturedFrame, rotated: Bool) -> CGImage? {
        var ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
        if rotated { ciImage = ciImage.oriented(.right) } // M0-11：仅显示层旋转
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }
}
