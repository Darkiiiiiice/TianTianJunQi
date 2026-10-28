import AppKit
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
    let autoSampler: BoardAutoSampler
    let perception: BoardPerceptionService
    let tapService: BoardTapService
    let injector: InputInjector
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
    @State private var screenSampleLabel: ScreenState = .main
    @State private var screenSampleCounts: [ScreenState: Int] = [:]
    @State private var screenSampleMessage = ""
    @State private var isSavingScreenSample = false

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
                case .modeLobby: Text("场次选择页").foregroundStyle(.green)
                case .matching: Text("匹配中…").foregroundStyle(.orange)
                case .board: Text("牌局")
                case .result: Text("结算页").foregroundStyle(.orange)
                case .popup:
                    Text("检测到弹窗 · \(screenState.popupResolution?.label ?? "未识别")")
                        .foregroundStyle(.orange)
                case .unknown: Text("未识别").foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("弹窗处理").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(modeEntry.lastPopupSummary ?? "—")
                        .foregroundStyle(
                            modeEntry.lastPopupSummary == nil ? Color.secondary : Color.orange
                        )
                    if let screenshot = modeEntry.lastPopupScreenshot {
                        Button("截图") {
                            NSWorkspace.shared.activateFileViewerSelecting([screenshot])
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help(screenshot.path)
                    }
                }
            }
            GridRow {
                Text("屏幕分类").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(screenState.isClassifierReady ? "模型" : "OCR 兜底")
                        .foregroundStyle(screenState.isClassifierReady ? .green : .secondary)
                    if screenState.stateSource == .ocr, screenState.state != .unknown {
                        Text("· OCR 覆盖").foregroundStyle(.orange)
                    }
                    if let confidence = screenState.classifierConfidence,
                       let milliseconds = screenState.classifierMilliseconds {
                        Text(String(format: "%.2f · %.0fms", confidence, milliseconds))
                            .foregroundStyle(.secondary)
                    }
                }
                .help(screenState.classifierStatus)
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

            screenSampleRow

            autoSampleRow

            perceptionRow

            tapRow

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

    /// M1-7：人工给当前界面打标签并采集屏幕样本，训练 7 类屏幕分类器。
    private var screenSampleRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Picker("屏幕样本", selection: $screenSampleLabel) {
                    ForEach(ScreenState.allCases) { state in
                        Text(state.label).tag(state)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.mini)
                .font(.caption)
                .frame(width: 104)

                Button {
                    captureScreenSample()
                } label: {
                    if isSavingScreenSample {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("采集屏幕", systemImage: "rectangle.dashed.badge.record")
                            .font(.caption)
                    }
                }
                .controlSize(.mini)
                .disabled(capture.latestFrame == nil || isSavingScreenSample)
                .help("把当前窗口内容区保存为屏幕分类样本，标签取自左侧菜单")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([StorageKit().screenSamplesURL])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.link)
                .controlSize(.mini)
                .help("打开屏幕样本目录")

                Text(screenSampleMessage.isEmpty ? screenSampleSummary : screenSampleMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(screenSampleSummary)

                Spacer(minLength: 0)
            }

            Text("屏幕分类样本：先切到目标界面，再选标签采集；`make screen-dataset` 导出后训练 7 类模型")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onAppear { refreshScreenSampleCounts() }
    }

    private var screenSampleSummary: String {
        let total = screenSampleCounts.values.reduce(0, +)
        guard total > 0 else { return "尚未采集" }
        let parts = ScreenState.allCases.compactMap { state -> String? in
            guard let count = screenSampleCounts[state], count > 0 else { return nil }
            return "\(state.label)\(count)"
        }
        return "已采集 \(total) 份 · " + parts.joined(separator: " · ")
    }

    private func refreshScreenSampleCounts() {
        screenSampleCounts = ScreenSampleExporter.counts()
    }

    private func captureScreenSample() {
        guard let frame = capture.latestFrame else {
            screenSampleMessage = "等待游戏画面"
            return
        }
        isSavingScreenSample = true
        screenSampleMessage = ""
        let label = screenSampleLabel
        let windowSize = windows.effectiveCandidate?.bounds.size
        let note = "predicted=\(screenState.state.rawValue) source=\(screenState.stateSource.rawValue)"
        Task {
            do {
                let url = try await Task.detached(priority: .utility) {
                    try ScreenSampleExporter().export(
                        frame: frame,
                        label: label,
                        windowSize: windowSize,
                        source: "manual",
                        note: note
                    )
                }.value
                screenSampleMessage = "已保存 \(url.lastPathComponent)"
                refreshScreenSampleCounts()
            } catch {
                screenSampleMessage = "采集失败：\(error.localizedDescription)"
            }
            isSavingScreenSample = false
        }
    }

    private var autoSampleRow: some View {
        HStack(spacing: 8) {
            Toggle(
                "棋盘变化自动采样",
                isOn: Binding(
                    get: { autoSampler.isEnabled },
                    set: { autoSampler.isEnabled = $0 }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(calibration.calibration == nil)
            .help(
                calibration.calibration == nil
                    ? "请先在设置页完成校准"
                    : "对局中检测到棋子变化后自动保存一份样本；等本局结束到「样本库」逐格标注"
            )

            Text(autoSampler.statusText)
                .font(.caption2)
                .foregroundStyle(autoSamplerStatusColor)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private var autoSamplerStatusColor: Color {
        switch autoSampler.phase {
        case .settling, .saving:
            return .purple
        case .paused, .failed:
            return .orange
        case .off, .waitingForBoard, .watching:
            return .secondary
        }
    }

    /// M1-4/M1-5：实时感知的稳定棋盘摘要 + 轮次/计时/可走格。
    private var perceptionRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Toggle(
                    "实时棋局感知",
                    isOn: Binding(
                        get: { perception.isEnabled },
                        set: { perception.isEnabled = $0 }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(calibration.calibration == nil)
                .help(
                    calibration.calibration == nil
                        ? "请先在设置页完成校准"
                        : "对局中逐帧跑棋子分类器并做 3 帧投票平滑，再构建 GameState"
                )

                Picker(
                    "我方执色",
                    selection: Binding(
                        get: { perception.myColor },
                        set: { perception.myColor = $0 }
                    )
                ) {
                    Text("红").tag(PieceColor.red)
                    Text("黑").tag(PieceColor.black)
                }
                .pickerStyle(.segmented)
                .font(.caption2)
                .frame(width: 76)
                .help("轮次与可走格都按这个执色判断")

                Text(perception.statusText)
                    .font(.caption2)
                    .foregroundStyle(perceptionStatusColor)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text(perception.detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(perception.stateJSON ?? "GameState JSON 尚未生成")

                Button("复制状态") {
                    guard let json = perception.stateJSON else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                }
                .buttonStyle(.link)
                .font(.caption2)
                .disabled(perception.stateJSON == nil)
                .help("把当前 GameState JSON 复制到剪贴板，便于对齐 shared/schema/game_state.schema.json")

                Spacer(minLength: 0)
            }
        }
    }

    /// M1-6：真实点击验证。默认关闭注入，开启后每次点击都必须由棋盘变化证实。
    private var tapRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Toggle(
                    "允许点击棋盘",
                    isOn: Binding(
                        get: { tapService.isArmed },
                        set: { tapService.isArmed = $0 }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("开启后会向游戏窗口注入真实鼠标点击；先用手动对局验证")

                Button("翻一个可翻格") {
                    Task { await verifyFlip() }
                }
                .buttonStyle(.link)
                .font(.caption2)
                .disabled(
                    !tapService.isArmed
                        || !permissions.controlReady
                        || tapService.phase != .idle
                        || perception.phase != .running
                        || windows.effectiveWindowID == nil
                )
                .help("从 GameState 的可走集合里挑一个暗格翻牌，并等待棋盘变化确认")

                Text(tapService.statusText)
                    .font(.caption2)
                    .foregroundStyle(tapStatusColor)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            Text(tapPointText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var tapPointText: String {
        let window = tapService.lastWindowPoint.map {
            String(format: "%.4f,%.4f", $0.x, $0.y)
        } ?? "—"
        let screen: String
        if let point = tapService.lastAbsolutePoint {
            screen = "\(Int(point.x)),\(Int(point.y))"
        } else {
            screen = "—"
        }
        return "点击目标 · 窗口内 \(window) · 屏幕 \(screen)"
    }

    private func verifyFlip() async {
        guard let board = perception.board,
              let state = perception.gameState,
              let cell = state.legalActions.first(where: { board.cells[$0].state == .hidden })
        else { return }
        await tapService.perform(
            .flip(cell: cell),
            capture: capture,
            windows: windows,
            calibration: calibration,
            screenState: screenState,
            perception: perception,
            injector: injector,
            store: store
        )
    }

    private var tapStatusColor: Color {
        guard let result = tapService.lastResult else { return .secondary }
        switch result {
        case .confirmed:
            return .green
        case .refused:
            return .secondary
        case .unverified:
            return .orange
        }
    }

    private var perceptionStatusColor: Color {
        switch perception.phase {
        case .settling:
            return .purple
        case .failed:
            return .orange
        case .off, .waitingForBoard:
            return .secondary
        case .running:
            return .green
        }
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

    /// 当前校准对应的 5×12 棋盘格点；列/行中心线来自校准时逐条拖出的位置。
    private var boardGrid: BoardGrid? {
        calibration.calibration?.boardGrid(rows: boardRows, cols: boardCols)
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
                        theme: theme,
                        origin: "manual"
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

            for row in 0..<grid.rows {
                for col in 0..<grid.cols {
                    let bounds = grid.cellRect(row: row, col: col)
                    var cell = Path()
                    cell.addLines([
                        displayPoint(grid.point(u: bounds.u0, v: bounds.v0)),
                        displayPoint(grid.point(u: bounds.u1, v: bounds.v0)),
                        displayPoint(grid.point(u: bounds.u1, v: bounds.v1)),
                        displayPoint(grid.point(u: bounds.u0, v: bounds.v1)),
                    ])
                    cell.closeSubpath()
                    context.stroke(cell, with: .color(.green.opacity(0.28)), lineWidth: 1)
                }
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
