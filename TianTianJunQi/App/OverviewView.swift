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
    let calibration: CalibrationStore
    let boardRows: Int
    let boardCols: Int
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
    @State private var showGrid = false
    @State private var isExporting = false
    @State private var showSnapshots = false

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
        .sheet(isPresented: $showSnapshots) {
            SnapshotBrowserView(rootURL: StorageKit().samplesURL)
        }
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
                        let rotated = shouldRotate(frame)
                        let size = fittedSize(
                            aspect: displayAspect(frame, rotated: rotated),
                            available: geo.size
                        )
                        ZStack {
                            Image(decorative: image, scale: frame.scale, orientation: .up)
                                .resizable()
                                .frame(width: size.width, height: size.height)
                            if showGrid, let grid = boardGrid {
                                gridOverlay(grid, size: size, rotated: rotated)
                            }
                        }
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

                Divider()
                    .frame(height: 14)

                Toggle("显示棋盘格点", isOn: $showGrid)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(calibration.calibration == nil)
                    .help(
                        calibration.calibration == nil
                            ? "请先在设置页完成校准"
                            : "在画面上叠加校准后的 \(boardRows)×\(boardCols) 格点"
                    )

                Divider()
                    .frame(height: 14)

                Button {
                    showSnapshots = true
                } label: {
                    Label("样本库", systemImage: "square.grid.3x3")
                        .font(.caption)
                }
                .controlSize(.mini)
                .help("浏览已采集的棋盘快照，并逐格标注空/暗子/明子")

                Button {
                    captureSnapshot()
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("采集样本", systemImage: "camera")
                            .font(.caption)
                    }
                }
                .controlSize(.mini)
                .disabled(!canCaptureSnapshot || isExporting)
                .help("保存当前整帧 + \(boardRows * boardCols) 个透视校正格子到 Application Support")
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

    /// 当前校准四角对应的 5×12 棋盘格点。
    private var boardGrid: BoardGrid? {
        guard let calibration = calibration.calibration,
              let quad = BoardQuad(corners: calibration.boardCorners)
        else { return nil }
        return BoardGrid(quad: quad, rows: boardRows, cols: boardCols)
    }

    private var canCaptureSnapshot: Bool {
        calibration.calibration != nil && capture.latestFrame != nil && boardGrid != nil
    }

    /// 保存当前帧与 60 个格子图，作为 M1-3 分类器的原始样本。
    private func captureSnapshot() {
        guard let frame = capture.latestFrame, let grid = boardGrid else {
            store.note("采集样本失败：请先完成校准并等待游戏画面")
            return
        }
        isExporting = true
        let windowSize = windows.effectiveCandidate?.bounds.size
        let theme = calibration.calibration?.theme

        Task {
            do {
                let url = try await Task.detached(priority: .utility) {
                    try BoardSnapshotExporter().export(
                        frame: frame,
                        grid: grid,
                        windowSize: windowSize,
                        theme: theme
                    )
                }.value
                store.note("棋盘样本已保存：\(url.path)")
                showSnapshots = true
            } catch {
                store.note("采集样本失败：\(error.localizedDescription)")
            }
            isExporting = false
        }
    }

    /// 在显示画面上叠加棋盘四边形、网格线与格心。
    /// 预览可能做了 90° 显示旋转，这里同步变换坐标（仅显示层）。
    private func gridOverlay(_ grid: BoardGrid, size: CGSize, rotated: Bool) -> some View {
        Canvas { context, canvasSize in
            func displayPoint(_ point: CGPoint) -> CGPoint {
                let mapped = rotated
                    ? CGPoint(x: 1 - point.y, y: point.x)
                    : point
                return CGPoint(
                    x: mapped.x * canvasSize.width,
                    y: mapped.y * canvasSize.height
                )
            }

            var outline = Path()
            outline.addLines(grid.quad.corners.map(displayPoint))
            outline.closeSubpath()
            context.stroke(
                outline,
                with: .color(.green.opacity(0.95)),
                style: StrokeStyle(lineWidth: 2, dash: [7, 4])
            )

            for row in 0...grid.rows {
                let v = CGFloat(row) / CGFloat(grid.rows)
                var line = Path()
                line.move(to: displayPoint(grid.point(u: 0, v: v)))
                line.addLine(to: displayPoint(grid.point(u: 1, v: v)))
                context.stroke(line, with: .color(.green.opacity(0.45)), lineWidth: 1)
            }
            for col in 0...grid.cols {
                let u = CGFloat(col) / CGFloat(grid.cols)
                var line = Path()
                line.move(to: displayPoint(grid.point(u: u, v: 0)))
                line.addLine(to: displayPoint(grid.point(u: u, v: 1)))
                context.stroke(line, with: .color(.green.opacity(0.45)), lineWidth: 1)
            }

            for center in grid.cellCenters {
                let point = displayPoint(center)
                let dot = Path(ellipseIn: CGRect(
                    x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2
                ))
                context.fill(dot, with: .color(.yellow))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
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
