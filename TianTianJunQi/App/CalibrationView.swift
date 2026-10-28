import AppKit
import CoreImage
import CoreVideo
import SwiftUI

/// 校准向导（M1-1）：在实时画面上框选画布、棋盘四角与常用按钮，
/// 归一化写入 `calibration.json`。所有坐标与 OCR/点击共用同一坐标系，
/// 因此窗口移动/缩放不影响已保存的锚点。
struct CalibrationView: View {
    let windows: WindowMonitor
    let capture: CaptureService
    let store: CalibrationStore

    @Environment(\.dismiss) private var dismiss
    @State private var step: CalibrationStep = .canvas
    @State private var draft = Draft()
    @State private var mask: BoardMask?
    @State private var hover: MaskHover?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var errorMessage: String?
    @State private var ciContext = CIContext()
    @State private var isDetecting = false

    private let profile: GameProfile

    init(windows: WindowMonitor, capture: CaptureService, store: CalibrationStore) {
        self.windows = windows
        self.capture = capture
        self.store = store
        self.profile = (try? StorageKit().loadGameProfile()) ?? .tianTianJunQi
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                preview
                Divider()
                sidebar
                    .frame(width: 320)
            }
            Divider()
            footer
        }
        .frame(minWidth: 980, minHeight: 680)
        .onAppear {
            loadDraft()
            if let id = windows.effectiveWindowID {
                Task { await capture.startOrSwitch(to: id) }
            }
        }
        .onChange(of: step) { _, newStep in
            dragStart = nil
            dragCurrent = nil
            errorMessage = nil
            if newStep == .board {
                ensureMask()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("校准向导")
                    .font(.title2.bold())
                Text("第 \(step.rawValue + 1) / \(CalibrationStep.allCases.count) 步 · \(step.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(CalibrationStep.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: item == step ? 26 : 14, height: 6)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Preview

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.92)

                if let frame = capture.latestFrame, let image = previewImage(frame) {
                    let aspect = CGFloat(image.width) / CGFloat(image.height)
                    let fitted = fittedRect(aspect: aspect, in: geo.size)

                    ZStack {
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: fitted.width, height: fitted.height)

                        overlay(size: fitted.size)

                        interactionLayer(size: fitted.size)
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    }
                    .position(x: fitted.midX, y: fitted.midY)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("等待游戏画面…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("请先打开微信小游戏，并确认概览页有实时画面")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(step.title)
                    .font(.headline)
                Text(step.instruction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(CalibrationStep.allCases) { item in
                        HStack(spacing: 8) {
                            Image(systemName: isComplete(item) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isComplete(item) ? .green : .secondary)
                            Text(item.title)
                                .font(.callout)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                }

                if step == .canvas {
                    Button("使用整个画面") {
                        draft.canvasROI = CGRect(x: 0, y: 0, width: 1, height: 1)
                    }
                    .controlSize(.small)
                }

                if step == .board {
                    HStack(spacing: 8) {
                        Button("自动对齐") { autoAlign() }
                            .controlSize(.small)
                            .disabled(capture.latestFrame == nil || isDetecting)
                        Button("重置居中") { resetMask() }
                            .controlSize(.small)
                        if isDetecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    HStack(spacing: 8) {
                        Text("整体")
                            .font(.caption)
                            .frame(width: 28, alignment: .leading)
                        Button("缩小") { scaleMask(by: 0.96) }
                        Button("放大") { scaleMask(by: 1.04) }
                    }
                    .controlSize(.small)

                    Divider()

                    VStack(alignment: .leading, spacing: 5) {
                        Text("逐列微调")
                            .font(.caption.bold())
                        ForEach(0..<cols, id: \.self) { index in
                            lineSlider(
                                "\(index + 1)",
                                value: columnBinding(index),
                                range: columnRange(index)
                            )
                        }
                        Button("中间列均分") {
                            mask = (boardMask ?? defaultMask()).uniformizedColumns()
                        }
                        .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("逐行微调")
                            .font(.caption.bold())
                        ForEach(0..<rows, id: \.self) { index in
                            lineSlider(
                                "\(index + 1)",
                                value: rowBinding(index),
                                range: rowRange(index)
                            )
                        }
                        Button("中间行均分") {
                            mask = (boardMask ?? defaultMask()).uniformizedRows()
                        }
                        .controlSize(.small)
                    }

                    HStack(spacing: 12) {
                        Text("移动")
                            .font(.caption)
                        VStack(spacing: 4) {
                            nudgeButton("arrow.up", dx: 0, dy: -0.0015)
                            HStack(spacing: 24) {
                                nudgeButton("arrow.left", dx: -0.0015, dy: 0)
                                nudgeButton("arrow.right", dx: 0.0015, dy: 0)
                            }
                            nudgeButton("arrow.down", dx: 0, dy: 0.0015)
                        }
                        Text("每步 0.15% · 按住 Shift 拖动可精调")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let text = maskAspectText {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(maskAspectMatches ? .green : .secondary)
                    }
                    Text("直接拖动画面里的青色中心线，黄点会落在棋子中心；每条线只移动自己，格子宽窄可以逐列不同。拖动空白处整体移动，滚轮或双指捏合整体缩放，双击复位。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let calibration = store.calibration {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已有校准")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("窗口 \(Int(calibration.windowSize.width))×\(Int(calibration.windowSize.height)) · 皮肤 \(calibration.theme)")
                            .font(.caption)
                        if let venue = calibration.buttons["venue"] {
                            Text("场次锚点 \(percentRect(venue))")
                                .font(.caption)
                        }
                    }
                }

                if let message = errorMessage ?? store.lastError {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                windowInfo
            }
            .padding(16)
        }
    }

    private var windowInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("窗口")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if let window = windows.effectiveCandidate {
                Text("\(window.title.isEmpty ? "已检测" : window.title) · \(Int(window.bounds.width))×\(Int(window.bounds.height))")
                    .font(.caption)
            } else {
                Text("未检测到游戏窗口")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let frame = capture.latestFrame {
                let width = CVPixelBufferGetWidth(frame.pixelBuffer)
                let height = CVPixelBufferGetHeight(frame.pixelBuffer)
                Text("抓帧 \(width)×\(height) · 内容 \(Int(Double(width) * frame.contentRect.width))×\(Int(Double(height) * frame.contentRect.height))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("锚点按归一化坐标保存，窗口移动/缩放后仍可用。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button("重来本步") { resetStep() }
                .disabled(!hasContent(for: step))

            Button("上一步") {
                if let previous = CalibrationStep(rawValue: step.rawValue - 1) {
                    step = previous
                }
            }
            .disabled(step == .canvas)

            Button(step == .board ? "保存校准" : "下一步") { advance() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isComplete(step))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Overlay

    private func overlay(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            switch step {
            case .canvas:
                stroke(draft.canvasROI, in: context, size: canvasSize, color: .green, dashed: true)
                label("画布区域", at: draft.canvasROI, in: context, size: canvasSize)
            case .board:
                if let mask = boardMask {
                    drawMask(mask, in: context, size: canvasSize)
                }
            case .entry:
                if let rect = draft.modeEntry {
                    stroke(rect, in: context, size: canvasSize, color: .green)
                    label("翻翻棋入口", at: rect, in: context, size: canvasSize)
                }
            case .venue:
                if let rect = draft.venue {
                    stroke(rect, in: context, size: canvasSize, color: .green)
                    label("新手场", at: rect, in: context, size: canvasSize)
                }
            }

            if let dragRect = currentDragRect {
                stroke(dragRect, in: context, size: canvasSize, color: .orange, dashed: true)
            }
        }
    }

    private func stroke(
        _ rect: CGRect,
        in context: GraphicsContext,
        size: CGSize,
        color: Color,
        dashed: Bool = false
    ) {
        let path = Path(normalizedRect(rect, in: size))
        let style = StrokeStyle(lineWidth: 2, dash: dashed ? [6, 4] : [])
        context.stroke(path, with: .color(color), style: style)
        if dashed {
            context.fill(path, with: .color(color.opacity(0.08)))
        }
    }

    private func label(
        _ text: String,
        at rect: CGRect,
        in context: GraphicsContext,
        size: CGSize
    ) {
        let frame = normalizedRect(rect, in: size)
        let resolved = context.resolve(
            Text(text).font(.caption.bold()).foregroundStyle(.white)
        )
        let textSize = resolved.measure(in: size)
        let background = CGRect(
            x: frame.minX + 5, y: frame.minY + 5,
            width: textSize.width + 10, height: textSize.height + 6
        )
        context.fill(
            Path(roundedRect: background, cornerRadius: 4),
            with: .color(.black.opacity(0.65))
        )
        context.draw(
            resolved,
            at: CGPoint(x: background.minX + 5, y: background.midY),
            anchor: .leading
        )
    }

    /// 画出外框、格子边界、可拖动中心线与黄色格心。
    /// 所有线条都从同一组中心线推导，保证屏幕显示与保存后的 `BoardGrid` 完全一致。
    private func drawMask(_ mask: BoardMask, in context: GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let rect = mask.rect
        let frame = CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )

        // 遮罩外压暗，避免背景干扰对齐。
        var dim = Path(CGRect(origin: .zero, size: size))
        dim.addRect(frame)
        context.fill(
            dim,
            with: .color(.black.opacity(0.45)),
            style: FillStyle(eoFill: true)
        )

        // 外框（由最外侧中心线推导）。
        context.stroke(Path(frame), with: .color(.green.opacity(0.9)), lineWidth: 1.5)

        // 每个训练格子的裁剪范围：以黄点为正中，白色细线。
        for row in 0..<mask.rowCenters.count {
            let ys = mask.rowBounds(row)
            for col in 0..<mask.columnCenters.count {
                let xs = mask.columnBounds(col)
                let cell = CGRect(
                    x: xs.lowerBound * size.width,
                    y: ys.lowerBound * size.height,
                    width: (xs.upperBound - xs.lowerBound) * size.width,
                    height: (ys.upperBound - ys.lowerBound) * size.height
                )
                context.stroke(Path(cell), with: .color(.white.opacity(0.22)), lineWidth: 1)
            }
        }

        // 可拖动中心线：悬停时橙色加粗。
        for (index, x) in mask.columnCenters.enumerated() {
            let px = x * size.width
            let active = hover?.column == index
            var line = Path()
            line.move(to: CGPoint(x: px, y: frame.minY))
            line.addLine(to: CGPoint(x: px, y: frame.maxY))
            context.stroke(
                line,
                with: .color(active ? .orange : .cyan.opacity(0.5)),
                lineWidth: active ? 2 : 1
            )
        }
        for (index, y) in mask.rowCenters.enumerated() {
            let py = y * size.height
            let active = hover?.row == index
            var line = Path()
            line.move(to: CGPoint(x: frame.minX, y: py))
            line.addLine(to: CGPoint(x: frame.maxX, y: py))
            context.stroke(
                line,
                with: .color(active ? .orange : .cyan.opacity(0.5)),
                lineWidth: active ? 2 : 1
            )
        }

        // 黄色格心 = 中心线交点。
        for y in mask.rowCenters {
            for x in mask.columnCenters {
                let center = CGPoint(x: x * size.width, y: y * size.height)
                let dot = Path(ellipseIn: CGRect(
                    x: center.x - 2.6, y: center.y - 2.6, width: 5.2, height: 5.2
                ))
                context.fill(dot, with: .color(.yellow))
            }
        }

        // 悬停中心线的编号提示。
        guard let hover else { return }
        let text: String
        let at: CGPoint
        if let column = hover.column, mask.columnCenters.indices.contains(column) {
            text = "列 \(column + 1)"
            at = CGPoint(
                x: mask.columnCenters[column] * size.width,
                y: frame.minY + 12
            )
        } else if let row = hover.row, mask.rowCenters.indices.contains(row) {
            text = "行 \(row + 1)"
            at = CGPoint(
                x: frame.minX + 28,
                y: mask.rowCenters[row] * size.height
            )
        } else {
            return
        }
        let resolved = context.resolve(
            Text(text).font(.caption2.bold()).foregroundStyle(.black)
        )
        let background = CGRect(x: at.x - 20, y: at.y - 9, width: 40, height: 18)
        context.fill(
            Path(roundedRect: background, cornerRadius: 4),
            with: .color(.orange.opacity(0.92))
        )
        context.draw(resolved, at: at, anchor: .center)
    }

    // MARK: - Interaction

    @ViewBuilder
    private func interactionLayer(size: CGSize) -> some View {
        if step == .board, let currentMask = boardMask {
            MaskInteractionView(
                columnCenters: currentMask.columnCenters,
                rowCenters: currentMask.rowCenters,
                onCentersChange: { columns, rows in
                    guard var updated = boardMask,
                          updated.columnCenters.count == columns.count,
                          updated.rowCenters.count == rows.count
                    else { return }
                    updated.columnCenters = columns
                    updated.rowCenters = rows
                    mask = updated.clamped()
                },
                onReset: { resetMask() },
                onHover: { hover = $0 }
            )
        } else if step != .board {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if dragStart == nil { dragStart = normalized(value.startLocation, in: size) }
                            dragCurrent = normalized(value.location, in: size)
                        }
                        .onEnded { value in
                            let start = dragStart ?? normalized(value.startLocation, in: size)
                            let end = normalized(value.location, in: size)
                            dragStart = nil
                            dragCurrent = nil
                            let rect = CGRect(
                                x: min(start.x, end.x),
                                y: min(start.y, end.y),
                                width: abs(end.x - start.x),
                                height: abs(end.y - start.y)
                            )
                            guard rect.width > 0.01, rect.height > 0.01 else { return }
                            switch step {
                            case .canvas: draft.canvasROI = rect
                            case .entry: draft.modeEntry = rect
                            case .venue: draft.venue = rect
                            case .board: break
                            }
                        }
                )
        }
    }

    // MARK: - Steps

    private enum CalibrationStep: Int, CaseIterable, Identifiable {
        case canvas
        case entry
        case venue
        case board

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .canvas: "游戏画布"
            case .entry: "翻翻棋入口"
            case .venue: "新手场按钮"
            case .board: "棋盘网格"
            }
        }

        var instruction: String {
            switch self {
            case .canvas:
                "让游戏停在主菜单（或任意完整画面），拖出实际游戏画布区域。若游戏已铺满整个画面，直接点「使用整个画面」。"
            case .entry:
                "让游戏回到主菜单，拖框选中「翻翻棋」入口按钮。需要切换界面时可以直接点游戏窗口，校准窗口不会关闭。OCR 失败时会点这个框的中心。"
            case .venue:
                "让游戏进入场次选择页，拖框选中「新手场」卡片。OCR 失败时会点这个框的中心。"
            case .board:
                "让游戏进入牌局。拖动画面里的 12 条竖向和 5 条横向青色中心线，让黄色格心落在每颗棋子中心。每条线只移动自己，格子宽窄可以不一样（中间河道会明显更宽）；侧栏滑杆可按列/行微调，双击画面复位。"
            }
        }
    }

    private struct Draft {
        var canvasROI = CGRect(x: 0, y: 0, width: 1, height: 1)
        var modeEntry: CGRect?
        var venue: CGRect?
    }

    // MARK: - Actions

    private func loadDraft() {
        guard let calibration = store.calibration else { return }
        draft.canvasROI = calibration.canvasROI
        draft.modeEntry = calibration.modeEntry
        draft.venue = calibration.buttons["venue"]

        if let quad = BoardQuad(corners: calibration.boardCorners), quad.isValid {
            mask = BoardMask(
                rect: quad.bounds,
                rows: rows,
                cols: cols,
                columnCenters: calibration.boardColumnCenters,
                rowCenters: calibration.boardRowCenters
            ).clamped()
        }
    }

    private func ensureMask() {
        if mask == nil {
            mask = defaultMask()
        }
        mask = mask?.clamped()
    }

    private func hasContent(for step: CalibrationStep) -> Bool {
        switch step {
        case .canvas: draft.canvasROI != CGRect(x: 0, y: 0, width: 1, height: 1)
        case .board: mask != nil
        case .entry: draft.modeEntry != nil
        case .venue: draft.venue != nil
        }
    }

    private func isComplete(_ step: CalibrationStep) -> Bool {
        switch step {
        case .canvas:
            draft.canvasROI.width > 0.05 && draft.canvasROI.height > 0.05
        case .board:
            draftGrid != nil
        case .entry:
            draft.modeEntry != nil
        case .venue:
            draft.venue != nil
        }
    }

    private func resetStep() {
        dragStart = nil
        dragCurrent = nil
        switch step {
        case .canvas: draft.canvasROI = CGRect(x: 0, y: 0, width: 1, height: 1)
        case .board: resetMask()
        case .entry: draft.modeEntry = nil
        case .venue: draft.venue = nil
        }
    }

    private func advance() {
        if let next = CalibrationStep(rawValue: step.rawValue + 1) {
            step = next
        } else {
            save()
        }
    }

    /// Vision 自动检测棋盘；结果只作为遮罩初值，仍可拖边/拖角继续微调。
    private func autoAlign() {
        guard let frame = capture.latestFrame else {
            errorMessage = "没有可用画面，无法自动对齐"
            return
        }
        let boardRows = rows
        let boardCols = cols
        isDetecting = true
        errorMessage = nil

        Task {
            let quad = await Task.detached(priority: .userInitiated) {
                BoardDetector.detect(in: frame, rows: boardRows, cols: boardCols)
            }.value

            isDetecting = false
            if let quad {
                mask = BoardMask.fitting(quad, rows: rows, cols: cols)
            } else {
                errorMessage = "未自动检测到棋盘；请拖动四条边或四个角手动对齐"
            }
        }
    }

    private func save() {
        guard let modeEntry = draft.modeEntry,
              let venue = draft.venue,
              let grid = draftGrid
        else {
            errorMessage = "还有未完成的校准项"
            return
        }
        guard let window = windows.effectiveCandidate else {
            errorMessage = "游戏窗口不存在，无法保存校准"
            return
        }

        let saved = store.save(
            canvasROI: draft.canvasROI,
            boardCorners: grid.quad.corners,
            boardColumnCenters: boardMask?.columnCenters,
            boardRowCenters: boardMask?.rowCenters,
            modeEntry: modeEntry,
            venue: venue,
            windowSize: window.bounds.size,
            theme: profile.board.theme
        )
        if saved {
            dismiss()
        } else {
            errorMessage = store.lastError
        }
    }

    // MARK: - Board mask

    private var rows: Int { profile.board.rows }
    private var cols: Int { profile.board.cols }

    /// 抓帧内容区的物理宽高比（宽 ÷ 高）。
    private var contentAspect: CGFloat? {
        guard let frame = capture.latestFrame else { return nil }
        let width = CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer)) * frame.contentRect.width
        let height = CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer)) * frame.contentRect.height
        guard width > 0, height > 0 else { return nil }
        return width / height
    }

    /// 当前画面的遮罩；始终夹紧到画面内，避免保存越界矩形。
    private var boardMask: BoardMask? {
        mask?.clamped()
    }

    /// 遮罩对应的格点；中心线数量必须与配置的行列数一致。
    private var draftGrid: BoardGrid? {
        guard let boardMask,
              boardMask.columnCenters.count == cols,
              boardMask.rowCenters.count == rows
        else { return nil }
        return boardMask.grid()
    }

    /// 默认遮罩：画面中央、按配置行列均分；之后可逐条拖动中心线。
    private func defaultMask() -> BoardMask {
        let width: CGFloat = 0.86
        let imageAspect = contentAspect ?? 1.55
        let height = min(
            0.92,
            width * imageAspect * CGFloat(rows) / CGFloat(cols)
        )
        return BoardMask(
            rect: CGRect(
                x: (1 - width) / 2,
                y: (1 - height) / 2,
                width: width,
                height: height
            ),
            rows: rows,
            cols: cols
        ).clamped()
    }

    private func resetMask() {
        mask = defaultMask()
    }

    private func zoomMask(by factor: CGFloat, anchor: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let current = boardMask ?? defaultMask()
        let normalizedAnchor = CGPoint(x: anchor.x / size.width, y: anchor.y / size.height)
        mask = current.zoomed(by: factor, anchor: normalizedAnchor)
    }

    /// 侧栏缩放按钮：围绕遮罩中心整体缩放。
    private func scaleMask(by factor: CGFloat) {
        let current = boardMask ?? defaultMask()
        mask = current.zoomed(by: factor, anchor: current.center)
    }

    private func nudgeMask(dx: CGFloat, dy: CGFloat) {
        let current = boardMask ?? defaultMask()
        mask = current.moved(by: CGSize(width: dx, height: dy))
    }

    private func nudgeButton(_ systemName: String, dx: CGFloat, dy: CGFloat) -> some View {
        Button {
            nudgeMask(dx: dx, dy: dy)
        } label: {
            Image(systemName: systemName)
                .frame(width: 24, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonRepeatBehavior(.enabled)
    }

    // MARK: - Mask guide lines

    private func columnBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                let centers = (boardMask ?? defaultMask()).columnCenters
                guard centers.indices.contains(index) else { return 0 }
                return Double(centers[index])
            },
            set: { value in
                let current = boardMask ?? defaultMask()
                mask = current.settingColumnCenter(index, to: CGFloat(value))
            }
        )
    }

    private func rowBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                let centers = (boardMask ?? defaultMask()).rowCenters
                guard centers.indices.contains(index) else { return 0 }
                return Double(centers[index])
            },
            set: { value in
                let current = boardMask ?? defaultMask()
                mask = current.settingRowCenter(index, to: CGFloat(value))
            }
        )
    }

    private func columnRange(_ index: Int) -> ClosedRange<Double> {
        let centers = (boardMask ?? defaultMask()).columnCenters
        guard centers.indices.contains(index) else { return 0...1 }
        let gap = BoardMask.minimumPitch
        let lower = index > 0 ? centers[index - 1] + gap : 0
        let upper = index < centers.count - 1 ? centers[index + 1] - gap : 1
        return Double(lower)...Double(max(lower, upper))
    }

    private func rowRange(_ index: Int) -> ClosedRange<Double> {
        let centers = (boardMask ?? defaultMask()).rowCenters
        guard centers.indices.contains(index) else { return 0...1 }
        let gap = BoardMask.minimumPitch
        let lower = index > 0 ? centers[index - 1] + gap : 0
        let upper = index < centers.count - 1 ? centers[index + 1] - gap : 1
        return Double(lower)...Double(max(lower, upper))
    }

    private func lineSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2.monospacedDigit())
                .frame(width: 20, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var maskTargetAspect: CGFloat {
        CGFloat(cols) / CGFloat(rows)
    }

    private var maskPhysicalAspect: CGFloat? {
        guard let boardMask, let imageAspect = contentAspect else { return nil }
        return boardMask.physicalAspect(imageAspect: imageAspect)
    }

    private var maskAspectMatches: Bool {
        guard let physical = maskPhysicalAspect else { return false }
        return abs(physical - maskTargetAspect) / maskTargetAspect < 0.04
    }

    private var maskAspectText: String? {
        guard let physical = maskPhysicalAspect else { return nil }
        let delta = (physical - maskTargetAspect) / maskTargetAspect * 100
        if abs(delta) < 4 {
            return String(
                format: "物理宽高比 %.2f · 目标 %.2f · 已接近标准比例",
                physical,
                maskTargetAspect
            )
        }
        return String(
            format: "物理宽高比 %.2f · 目标 %.2f（%+.0f%%）· 自由调整不影响保存",
            physical,
            maskTargetAspect,
            delta
        )
    }

    private func previewImage(_ frame: CapturedFrame) -> CGImage? {
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        if frame.contentRect != CapturedFrame.fullFrame {
            let extent = image.extent
            let crop = CGRect(
                x: extent.minX + frame.contentRect.minX * extent.width,
                y: extent.minY + frame.contentRect.minY * extent.height,
                width: frame.contentRect.width * extent.width,
                height: frame.contentRect.height * extent.height
            )
            image = image.cropped(to: crop)
        }
        return ciContext.createCGImage(image, from: image.extent)
    }

    private func fittedRect(aspect: CGFloat, in available: CGSize) -> CGRect {
        guard aspect > 0, available.width > 0, available.height > 0 else { return .zero }
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        return CGRect(
            x: (available.width - width) / 2,
            y: (available.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(
            x: min(max(point.x / size.width, 0), 1),
            y: min(max(point.y / size.height, 0), 1)
        )
    }

    private func local(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func normalizedRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }

    private var currentDragRect: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func percentRect(_ rect: CGRect) -> String {
        "\(Int(rect.minX * 100)),\(Int(rect.minY * 100)) "
            + "\(Int(rect.width * 100))×\(Int(rect.height * 100))%"
    }
}

/// 鼠标悬停的引导线。
private struct MaskHover: Equatable {
    var column: Int? = nil
    var row: Int? = nil
}

/// 遮罩交互层：拖动任意一条列/行中心线、拖动空白处整体平移、
/// 滚轮/触控板捏合整体缩放、双击复位。
/// SwiftUI 没有跨版本的滚轮手势，这里用 AppKit 视图接住 scrollWheel/magnify。
private struct MaskInteractionView: NSViewRepresentable {
    /// 归一化中心线坐标（相对预览画面）。
    var columnCenters: [CGFloat]
    var rowCenters: [CGFloat]
    var onCentersChange: ([CGFloat], [CGFloat]) -> Void
    var onReset: () -> Void
    var onHover: (MaskHover) -> Void

    func makeNSView(context: Context) -> MaskEventView {
        let view = MaskEventView()
        configure(view)
        return view
    }

    func updateNSView(_ view: MaskEventView, context: Context) {
        configure(view)
    }

    private func configure(_ view: MaskEventView) {
        view.columnCenters = columnCenters
        view.rowCenters = rowCenters
        view.onCentersChange = onCentersChange
        view.onReset = onReset
        view.onHover = onHover
    }
}

private final class MaskEventView: NSView {
    var columnCenters: [CGFloat] = []
    var rowCenters: [CGFloat] = []
    var onCentersChange: (([CGFloat], [CGFloat]) -> Void)?
    var onReset: (() -> Void)?
    var onHover: ((MaskHover) -> Void)?

    private enum DragMode: Equatable {
        case move
        case column(Int)
        case row(Int)
    }

    private var dragMode: DragMode?
    private var dragStartPoint: CGPoint?
    private var dragStartColumns: [CGFloat] = []
    private var dragStartRows: [CGFloat] = []
    private var lastHover = MaskHover()
    private var tracking: NSTrackingArea?

    /// 中心线命中带宽度（点）。
    private let hitWidth: CGFloat = 8
    /// 拖动时相邻中心线的最小间距（点），避免把格子压成一条线。
    private let minimumGap: CGFloat = 18

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        if event.clickCount == 2 {
            onReset?()
            return
        }
        guard let mode = hitTest(at: point) else { return }
        dragMode = mode
        dragStartPoint = point
        dragStartColumns = columnCenters
        dragStartRows = rowCenters

        switch mode {
        case .move:
            NSCursor.closedHand.set()
        case .column:
            NSCursor.resizeLeftRight.set()
        case .row:
            NSCursor.resizeUpDown.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mode = dragMode,
              let startPoint = dragStartPoint,
              bounds.width > 0, bounds.height > 0,
              !dragStartColumns.isEmpty, !dragStartRows.isEmpty
        else { return }

        let point = location(of: event)
        let precision: CGFloat = event.modifierFlags.contains(.shift) ? 0.2 : 1
        let dx = (point.x - startPoint.x) * precision / bounds.width
        let dy = (point.y - startPoint.y) * precision / bounds.height
        let gapX = max(BoardMask.minimumPitch, minimumGap / bounds.width)
        let gapY = max(BoardMask.minimumPitch, minimumGap / bounds.height)

        var columns = dragStartColumns
        var rows = dragStartRows

        switch mode {
        case .move:
            guard let minX = columns.first, let maxX = columns.last,
                  let minY = rows.first, let maxY = rows.last
            else { return }
            let shiftX = min(max(dx, -minX), 1 - maxX)
            let shiftY = min(max(dy, -minY), 1 - maxY)
            columns = columns.map { $0 + shiftX }
            rows = rows.map { $0 + shiftY }

        case .column(let index):
            guard columns.indices.contains(index) else { return }
            let lower = index > 0 ? columns[index - 1] + gapX : 0
            let upper = index < columns.count - 1 ? columns[index + 1] - gapX : 1
            columns[index] = min(
                max(columns[index] + dx, lower),
                max(lower, upper)
            )

        case .row(let index):
            guard rows.indices.contains(index) else { return }
            let lower = index > 0 ? rows[index - 1] + gapY : 0
            let upper = index < rows.count - 1 ? rows[index + 1] - gapY : 1
            rows[index] = min(
                max(rows[index] + dy, lower),
                max(lower, upper)
            )
        }

        columnCenters = columns
        rowCenters = rows
        onCentersChange?(columns, rows)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
        dragStartPoint = nil
        dragStartColumns = []
        dragStartRows = []
        updateCursor(at: location(of: event))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: location(of: event))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: location(of: event))
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.001 else { return }
        // 触控板给像素增量，鼠标滚轮给行数；分开取灵敏度。
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
        let factor = exp(min(max(delta * sensitivity, -0.5), 0.5))
        applyZoom(factor, anchor: location(of: event))
    }

    override func magnify(with event: NSEvent) {
        let factor = min(max(1 + event.magnification, 0.2), 5)
        applyZoom(factor, anchor: location(of: event))
    }

    // MARK: - Geometry

    /// 归一化中心线构造的遮罩；同时校验行列顺序。
    private var normalizedMask: BoardMask? {
        BoardMask(columnCenters: columnCenters, rowCenters: rowCenters)
    }

    /// 外框（像素坐标），拖动空白处时用于判断是否在棋盘内。
    private var boardFrame: CGRect {
        guard let mask = normalizedMask else { return .zero }
        let rect = mask.rect
        return CGRect(
            x: rect.minX * bounds.width,
            y: rect.minY * bounds.height,
            width: rect.width * bounds.width,
            height: rect.height * bounds.height
        )
    }

    /// 命中最接近的一条中心线；两条都在范围内时取更近的。
    private func hitTest(at point: CGPoint) -> DragMode? {
        guard bounds.width > 0, bounds.height > 0,
              !columnCenters.isEmpty, !rowCenters.isEmpty
        else { return nil }

        var bestColumn: (index: Int, distance: CGFloat)?
        for (index, value) in columnCenters.enumerated() {
            let distance = abs(value * bounds.width - point.x)
            if distance <= hitWidth,
               distance < (bestColumn?.distance ?? .greatestFiniteMagnitude) {
                bestColumn = (index, distance)
            }
        }

        var bestRow: (index: Int, distance: CGFloat)?
        for (index, value) in rowCenters.enumerated() {
            let distance = abs(value * bounds.height - point.y)
            if distance <= hitWidth,
               distance < (bestRow?.distance ?? .greatestFiniteMagnitude) {
                bestRow = (index, distance)
            }
        }

        if let column = bestColumn, let row = bestRow {
            return column.distance <= row.distance
                ? .column(column.index)
                : .row(row.index)
        }
        if let column = bestColumn { return .column(column.index) }
        if let row = bestRow { return .row(row.index) }
        if boardFrame.contains(point) { return .move }
        return nil
    }

    /// 以鼠标位置为不动点整体缩放；放大不越界、缩小不把格子压扁。
    private func applyZoom(_ factor: CGFloat, anchor: CGPoint) {
        guard bounds.width > 0, bounds.height > 0,
              !columnCenters.isEmpty, !rowCenters.isEmpty
        else { return }

        let ax = min(max(anchor.x / bounds.width, 0), 1)
        let ay = min(max(anchor.y / bounds.height, 0), 1)
        var target = min(max(factor, 0.2), 5)
        target = min(target, maximumZoomFactor(anchorX: ax, anchorY: ay))
        let floor = minZoomFactor()
        if target < 1 {
            target = max(target, min(floor, 1))
        }
        guard abs(target - 1) > 0.0001 else { return }

        let columns = columnCenters.map {
            min(max(ax + ($0 - ax) * target, 0), 1)
        }
        let rows = rowCenters.map {
            min(max(ay + ($0 - ay) * target, 0), 1)
        }
        columnCenters = columns
        rowCenters = rows
        onCentersChange?(columns, rows)
    }

    /// 放大时最外侧中心线不越过画面边界。
    private func maximumZoomFactor(anchorX: CGFloat, anchorY: CGFloat) -> CGFloat {
        var maximum = CGFloat.greatestFiniteMagnitude
        for value in columnCenters {
            if value > anchorX {
                maximum = min(maximum, (1 - anchorX) / (value - anchorX))
            } else if value < anchorX {
                maximum = min(maximum, anchorX / (anchorX - value))
            }
        }
        for value in rowCenters {
            if value > anchorY {
                maximum = min(maximum, (1 - anchorY) / (value - anchorY))
            } else if value < anchorY {
                maximum = min(maximum, anchorY / (anchorY - value))
            }
        }
        return max(1, maximum)
    }

    /// 缩小到相邻中心线间距仍大于最小命中间距。
    private func minZoomFactor() -> CGFloat {
        let gapX = max(BoardMask.minimumPitch, minimumGap / bounds.width)
        let gapY = max(BoardMask.minimumPitch, minimumGap / bounds.height)
        let pitchX = averagePitch(columnCenters)
        let pitchY = averagePitch(rowCenters)

        var floor: CGFloat = 0.2
        if pitchX > 0 { floor = max(floor, gapX / pitchX) }
        if pitchY > 0 { floor = max(floor, gapY / pitchY) }
        return floor
    }

    private func averagePitch(_ centers: [CGFloat]) -> CGFloat {
        guard centers.count > 1, let first = centers.first, let last = centers.last else {
            return 0
        }
        return (last - first) / CGFloat(centers.count - 1)
    }

    // MARK: - Cursor

    private func updateCursor(at point: CGPoint) {
        let mode = dragMode ?? hitTest(at: point)
        let hover: MaskHover
        switch mode {
        case .none:
            NSCursor.arrow.set()
            hover = MaskHover()
        case .move:
            NSCursor.openHand.set()
            hover = MaskHover()
        case .column(let index):
            NSCursor.resizeLeftRight.set()
            hover = MaskHover(column: index)
        case .row(let index):
            NSCursor.resizeUpDown.set()
            hover = MaskHover(row: index)
        }
        if hover != lastHover {
            lastHover = hover
            onHover?(hover)
        }
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseExited(with event: NSEvent) {
        if dragMode == nil {
            NSCursor.arrow.set()
            if lastHover != MaskHover() {
                lastHover = MaskHover()
                onHover?(lastHover)
            }
        }
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}
