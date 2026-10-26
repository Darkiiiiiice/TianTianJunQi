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
        .onChange(of: step) { _, _ in
            dragStart = nil
            dragCurrent = nil
            errorMessage = nil
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

                if step == .corners {
                    HStack {
                        Text("已选 \(draft.corners.count)/4 个角")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("撤销上一个") {
                            if !draft.corners.isEmpty { draft.corners.removeLast() }
                        }
                        .controlSize(.small)
                        .disabled(draft.corners.isEmpty)
                    }
                    HStack(spacing: 8) {
                        Button("自动检测四角") { detectCorners() }
                            .controlSize(.small)
                            .disabled(capture.latestFrame == nil || isDetecting)
                        if isDetecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
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

            Button(step == .venue ? "保存校准" : "下一步") { advance() }
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
            case .corners:
                if draft.corners.count >= 2 {
                    var path = Path()
                    path.addLines(draft.corners.map { local($0, in: canvasSize) })
                    if draft.corners.count == 4 { path.closeSubpath() }
                    context.stroke(path, with: .color(.green), lineWidth: 2)
                }
                for (index, corner) in draft.corners.enumerated() {
                    let point = local(corner, in: canvasSize)
                    let circle = Path(ellipseIn: CGRect(
                        x: point.x - 11, y: point.y - 11, width: 22, height: 22
                    ))
                    context.fill(circle, with: .color(.green))
                    context.draw(
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black),
                        at: point, anchor: .center
                    )
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

    // MARK: - Interaction

    @ViewBuilder
    private func interactionLayer(size: CGSize) -> some View {
        if step == .corners {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            guard draft.corners.count < 4 else { return }
                            draft.corners.append(normalized(value.location, in: size))
                        }
                )
        } else {
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
                            case .corners: break
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
        case corners

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .canvas: "游戏画布"
            case .entry: "翻翻棋入口"
            case .venue: "新手场按钮"
            case .corners: "棋盘四角"
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
            case .corners:
                "让游戏进入牌局，依次点击棋盘的四个角：左上 → 右上 → 右下 → 左下。点错可撤销或重来。"
            }
        }
    }

    private struct Draft {
        var canvasROI = CGRect(x: 0, y: 0, width: 1, height: 1)
        var corners: [CGPoint] = []
        var modeEntry: CGRect?
        var venue: CGRect?
    }

    // MARK: - Actions

    private func loadDraft() {
        guard let calibration = store.calibration else { return }
        draft.canvasROI = calibration.canvasROI
        draft.corners = calibration.boardCorners
        draft.modeEntry = calibration.modeEntry
        draft.venue = calibration.buttons["venue"]
    }

    private func hasContent(for step: CalibrationStep) -> Bool {
        switch step {
        case .canvas: draft.canvasROI != CGRect(x: 0, y: 0, width: 1, height: 1)
        case .corners: !draft.corners.isEmpty
        case .entry: draft.modeEntry != nil
        case .venue: draft.venue != nil
        }
    }

    private func isComplete(_ step: CalibrationStep) -> Bool {
        switch step {
        case .canvas:
            draft.canvasROI.width > 0.05 && draft.canvasROI.height > 0.05
        case .corners:
            draft.corners.count == 4
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
        case .corners: draft.corners = []
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

    /// Vision 自动检测四角；失败时保留手动点选能力。
    private func detectCorners() {
        guard let frame = capture.latestFrame else {
            errorMessage = "没有可用画面，无法自动检测"
            return
        }
        isDetecting = true
        errorMessage = nil

        Task {
            let quad = await Task.detached(priority: .userInitiated) {
                BoardDetector.detect(
                    in: frame,
                    rows: profile.board.rows,
                    cols: profile.board.cols
                )
            }.value

            isDetecting = false
            if let quad {
                draft.corners = quad.corners
            } else {
                errorMessage = "未自动检测到棋盘；请手动点选四个角"
            }
        }
    }

    private func save() {
        guard let modeEntry = draft.modeEntry,
              let venue = draft.venue,
              draft.corners.count == 4
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
            boardCorners: draft.corners,
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

    // MARK: - Geometry

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
