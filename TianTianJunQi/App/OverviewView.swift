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
    let modeEntry: ModeEntry
    /// 调试：只验证入口点击，不点场次卡（不开始真人匹配）。
    @Binding var entryOnly: Bool
    let onEnterMode: () -> Void
    let onPause: () -> Void
    let onEmergencyStop: () -> Void

    /// M0-11：预览方向。仅显示层变换，不影响感知/注入坐标链。
    private enum PreviewRotation: String, CaseIterable, Identifiable {
        case auto = "自动"
        case original = "原图"
        case rotated = "旋转 90°"
        var id: String { rawValue }
    }

    @State private var ciContext = CIContext()
    @State private var previewRotation: PreviewRotation = .auto

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 24) {
                statusSection
                actionSection
                Spacer()
            }
            .frame(width: 340, alignment: .leading)

            // 预览占满剩余空间，并随窗口尺寸自适应（M0-11）。
            liveSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                case .main:
                    if screenState.entryRect != nil {
                        Text("主菜单 · 入口已定位").foregroundStyle(.green)
                    } else {
                        Text("主菜单 · 入口用校准锚点").foregroundStyle(.green)
                    }
                case .venue: Text("场次选择页").foregroundStyle(.green)
                case .matching: Text("匹配中…").foregroundStyle(.orange)
                case .board: Text("牌局")
                case .result: Text("结算页").foregroundStyle(.orange)
                case .popup: Text("检测到弹窗").foregroundStyle(.orange)
                case .unknown: Text("未识别（OCR 运行中）").foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("模式 / 对手").foregroundStyle(.secondary)
                Text("翻翻棋 · 新手场（真人匹配）")
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
                } else if permissions.controlReady {
                    Text("进入就绪；录制缺 输入监控")
                        .foregroundStyle(.green)
                } else {
                    Text("缺 \(permissions.missing.filter { $0 != .inputMonitoring }.map(\.label).joined(separator: "、"))")
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
        if !permissions.controlReady {
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
                Button(modeEntry.isRunning ? "进入中…" : "进入翻翻棋") { onEnterMode() }
                    .disabled(
                        modeEntry.isRunning || !permissions.controlReady || windows.effectiveWindowID == nil
                    )
                Button("自动对局") {}
                    .disabled(true)
                Button("暂停") { onPause() }
                    .disabled(!modeEntry.isRunning)
                Button("急停", role: .destructive) { onEmergencyStop() }
                    .disabled(!modeEntry.isRunning)
            }
            .buttonStyle(.bordered)

            if let step = modeEntry.currentStep {
                Text("进行中：\(step)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let summary = modeEntry.lastSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("只验证入口点击（不开始真人匹配）", isOn: $entryOnly)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("M0-8：主菜单 → 新手场 → 真人匹配 → 棋盘；未知界面/匹配超时会暂停，自动对局待 Session 闭环")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 实时画面：读取 latestFrame，@Observable 驱动按帧刷新。
    /// 画面按可用空间等比放到最大，容器尺寸 = 画面尺寸，避免 scaledToFit 留下大块黑边。
    private var liveSection: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack {
                    if let frame = capture.latestFrame,
                       let image = frameImage(frame, rotated: shouldRotate(frame)) {
                        let size = fittedSize(
                            aspect: displayAspect(frame, rotated: shouldRotate(frame)),
                            available: geo.size
                        )
                        Image(decorative: image, scale: frame.scale, orientation: .up)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.quaternary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Picker("画面方向", selection: $previewRotation) {
                    ForEach(PreviewRotation.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.mini)
                .font(.caption)
                .frame(width: 104)

                Text(rotationLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = capture.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else {
                Text(frameInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var frameInfo: String {
        guard let frame = capture.latestFrame else { return "等待游戏窗口…" }
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let contentWidth = Int(Double(width) * frame.contentRect.width)
        let contentHeight = Int(Double(height) * frame.contentRect.height)
        let rate = capture.isCapturing ? "15fps" : "已暂停"
        return "实时画面 · \(contentWidth)×\(contentHeight)"
            + "（裁自 \(width)×\(height)）· \(rate)"
    }

    /// 显示后的宽高比（旋转时宽高互换），按裁剪后的内容区计算。
    private func displayAspect(_ frame: CapturedFrame, rotated: Bool) -> CGFloat {
        let width = CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer)) * frame.contentRect.width
        let height = CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer)) * frame.contentRect.height
        guard width > 0, height > 0 else { return 1 }
        return rotated ? height / width : width / height
    }

    /// 在可用区域内按宽高比放到最大。
    private func fittedSize(aspect: CGFloat, available: CGSize) -> CGSize {
        guard aspect > 0, available.width > 0, available.height > 0 else {
            return .zero
        }
        let width = min(available.width, available.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    /// 自动模式：窗口是竖的（高 > 宽）就顺时针转正；否则保持原样。
    private func shouldRotate(_ frame: CapturedFrame) -> Bool {
        switch previewRotation {
        case .rotated:
            return true
        case .original:
            return false
        case .auto:
            return CVPixelBufferGetHeight(frame.pixelBuffer)
                > CVPixelBufferGetWidth(frame.pixelBuffer)
        }
    }

    private var rotationLabel: String {
        guard let frame = capture.latestFrame else { return "等待画面" }
        switch previewRotation {
        case .auto:
            return shouldRotate(frame) ? "自动 · 竖屏已转正" : "自动 · 原始画面"
        case .original:
            return "原图"
        case .rotated:
            return "已旋转 90°"
        }
    }

    private func frameImage(_ frame: CapturedFrame, rotated: Bool) -> CGImage? {
        var ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
        // 裁到游戏内容区：SCStream 帧是小游戏原生画布，四周有黑边。
        let extent = ciImage.extent
        if frame.contentRect != CapturedFrame.fullFrame {
            let crop = CGRect(
                x: extent.minX + frame.contentRect.minX * extent.width,
                y: extent.minY + frame.contentRect.minY * extent.height,
                width: frame.contentRect.width * extent.width,
                height: frame.contentRect.height * extent.height
            )
            ciImage = ciImage.cropped(to: crop)
        }
        if rotated { ciImage = ciImage.oriented(.right) } // M0-11：仅显示层旋转
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }
}
