import AppKit
import SwiftUI

/// 样本库（M1-3 标注）：浏览 `perception/samples` 下的快照，
/// 逐格标 empty/hidden/红黑明子，写回 `labels.json`。
/// 训练集导出在后续里程碑补；此处先保证采集 → 人工校验 → 标注闭环。
struct SnapshotBrowserView: View {
    let rootURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [SnapshotSummary] = []
    @State private var selectedSnapshotID: String?
    @State private var manifest: BoardSnapshotManifest?
    @State private var labels: SnapshotLabels?
    @State private var images: [Int: NSImage] = [:]
    @State private var selectedCell = 0
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var filter: ReviewFilter = .all
    @State private var originFilter: OriginFilter = .all
    @State private var autoLabeling = false
    @State private var autoStatus: String?

    private enum ReviewFilter: String, CaseIterable, Identifiable {
        case all
        case unknown
        case auto

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "全部"
            case .unknown: "未标"
            case .auto: "自动"
            }
        }
    }

    /// 快照来源筛选：自动采样 / 手动采集 / 全部。
    private enum OriginFilter: String, CaseIterable, Identifiable {
        case all
        case auto
        case manual

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "全部"
            case .auto: "自动采样"
            case .manual: "手动"
            }
        }
    }

    private var library: SnapshotLibrary { SnapshotLibrary(rootURL: rootURL) }
    private var selectedSummary: SnapshotSummary? {
        snapshots.first { $0.id == selectedSnapshotID }
    }
    private var visibleSnapshots: [SnapshotSummary] {
        switch originFilter {
        case .all: snapshots
        case .auto: snapshots.filter(\.isAutoSampled)
        case .manual: snapshots.filter { !$0.isAutoSampled }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 230)
                Divider()
                gridPane
                Divider()
                inspector
                    .frame(width: 250)
            }
        }
        .frame(minWidth: 1180, minHeight: 720)
        .onAppear { reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("棋盘样本库")
                    .font(.title2.bold())
                Text("整帧 + 60 格透视图 · 标签写入各快照的 labels.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(visibleSnapshots.count) 份快照")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("刷新") { reload() }
                .controlSize(.small)
            Button("打开样本文件夹") {
                guard FileManager.default.fileExists(atPath: rootURL.path) else {
                    message = "样本目录还没有生成"
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([rootURL])
            }
            .controlSize(.small)
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("快照")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)

            Picker("来源", selection: $originFilter) {
                ForEach(OriginFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .help("自动 = 对局中棋盘变化后自动采集；手动 = 概览页「采集样本」")

            if visibleSnapshots.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "camera.on.rectangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(snapshots.isEmpty ? "还没有样本" : "没有符合筛选的快照")
                        .font(.callout)
                    if snapshots.isEmpty {
                        Text("完成校准后，在概览页点击「采集样本」")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleSnapshots) { summary in
                            snapshotRow(summary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .onChange(of: originFilter) { _, _ in
            guard let selectedSnapshotID,
                  visibleSnapshots.contains(where: { $0.id == selectedSnapshotID })
            else {
                if let first = visibleSnapshots.first { select(first) }
                return
            }
        }
    }

    private func snapshotRow(_ summary: SnapshotSummary) -> some View {
        let selected = summary.id == selectedSnapshotID
        return Button {
            select(summary)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: summary.isValidManifest ? "square.grid.3x3" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(summary.isValidManifest ? Color.secondary : Color.orange)
                    Text(shortTimestamp(summary.id))
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                    Spacer()
                    if summary.isAutoSampled {
                        Text("自动")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                .purple.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 3)
                            )
                    }
                    if hasLabels(summary) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                }
                if let rows = summary.rows, let cols = summary.cols {
                    Text("\(rows)×\(cols) · \(rows * cols) 格\(windowText(summary))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("meta.json 无法读取")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    private var gridPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = selectedSummary, let manifest, let labels {
                gridHeader(summary: summary, manifest: manifest, labels: labels)
                Divider()
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 5),
                            count: manifest.cols
                        ),
                        spacing: 5
                    ) {
                        ForEach(manifest.cells, id: \.index) { cell in
                            cellButton(cell)
                        }
                    }
                    .padding(16)
                }
                Divider()
                gridFooter(labels: labels)
            } else if selectedSummary != nil {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text("这份快照的 meta.json 无法读取")
                        .font(.callout)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("选择左侧快照查看 60 格")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gridHeader(
        summary: SnapshotSummary,
        manifest: BoardSnapshotManifest,
        labels: SnapshotLabels
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortTimestamp(summary.id))
                    .font(.headline.monospacedDigit())
                Text(
                    "\(manifest.rows)×\(manifest.cols) · 窗口 "
                        + "\(Int(manifest.windowSize?.width ?? 0))×\(Int(manifest.windowSize?.height ?? 0))"
                        + " · 皮肤 \(manifest.theme ?? "未知")"
                        + (summary.isAutoSampled ? " · 自动采样" : "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()

            Picker("筛选", selection: $filter) {
                ForEach(ReviewFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)

            HStack(spacing: 6) {
                Text("已标 \(labels.completeCount)/\(labels.cells.count)")
                    .font(.caption)
                    .foregroundStyle(labels.isComplete ? Color.green : Color.orange)
                if labels.autoCount > 0 {
                    Text("· 自动 \(labels.autoCount)")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                if labels.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            .fixedSize()

            if autoLabeling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(autoStatus ?? "自动标注中…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                }
            } else {
                Menu {
                    Button("自动标注当前快照") {
                        runAutoLabel(on: [summary])
                    }
                    Button("自动标注全部未完成快照") {
                        autoLabelAllPending()
                    }
                } label: {
                    Label("自动标注", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func gridFooter(labels: SnapshotLabels) -> some View {
        HStack(spacing: 14) {
            legend(color: .secondary, text: "未标")
            legend(color: .blue, text: "空")
            legend(color: .orange, text: "暗子")
            legend(color: .red, text: "红方明子")
            legend(color: .primary, text: "黑方明子")
            Spacer()
            Text("点击格子编辑；标签自动保存")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func cellButton(_ cell: BoardSnapshotManifest.Cell) -> some View {
        let label = labels?.label(at: cell.index)
        return Button {
            selectedCell = cell.index
        } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image = images[cell.index] {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(.quaternary)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipped()

                if let label, label.state == .revealed {
                    Text(label.piece ?? "?")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                        .padding(2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if label?.auto == true {
                    Text("AI")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.purple.opacity(0.92), in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        borderColor(label),
                        style: StrokeStyle(
                            lineWidth: cell.index == selectedCell ? 3 : 1.5,
                            dash: label?.auto == true ? [4, 3] : []
                        )
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(matchesFilter(label) ? 1 : 0.16)
        }
        .buttonStyle(.plain)
        .help("第 \(cell.row) 行 · 第 \(cell.col) 列 · 索引 \(cell.index)")
    }

    private func matchesFilter(_ label: SnapshotCellLabel?) -> Bool {
        switch filter {
        case .all: true
        case .unknown: label?.state == .unknown
        case .auto: label?.auto == true
        }
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let summary = selectedSummary, let manifest, let labels,
                   labels.cells.indices.contains(selectedCell),
                   let cell = manifest.cells.first(where: { $0.index == selectedCell }) {
                    inspectorContent(
                        summary: summary,
                        manifest: manifest,
                        labels: labels,
                        cell: cell,
                        label: labels.cells[selectedCell]
                    )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("选择一份快照与格子")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private func inspectorContent(
        summary: SnapshotSummary,
        manifest: BoardSnapshotManifest,
        labels: SnapshotLabels,
        cell: BoardSnapshotManifest.Cell,
        label: SnapshotCellLabel
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                if let image = images[cell.index] {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 180)
            .frame(maxWidth: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor(label), lineWidth: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text("第 \(cell.row) 行 · 第 \(cell.col) 列")
                    .font(.headline)
                Text("索引 \(cell.index) · \(label.displayLabel)")
                    .font(.caption)
                    .foregroundStyle(label.isComplete ? Color.secondary : Color.orange)
                if label.auto == true {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                        Text("自动标注 · 待人工确认")
                        Spacer()
                        Button("确认") {
                            updateSelected { $0.confirm() }
                        }
                        .controlSize(.mini)
                    }
                    .font(.caption2)
                    .foregroundStyle(.purple)
                }
            }

            Divider()

            Text("状态")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Picker("状态", selection: stateBinding(label: label)) {
                Text("未标").tag(CellState.unknown)
                Text("空").tag(CellState.empty)
                Text("暗子").tag(CellState.hidden)
                Text("明子").tag(CellState.revealed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if label.state == .revealed {
                Text("颜色")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Picker("颜色", selection: colorBinding(label: label)) {
                    Text("红方").tag(PieceColor.red)
                    Text("黑方").tag(PieceColor.black)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("棋子")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Picker("棋子", selection: pieceBinding(label: label)) {
                    Text("未选择").tag("")
                    ForEach(PieceCatalog.all, id: \.self) { piece in
                        Text(piece).tag(piece)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Button("全部标为暗子") {
                    setAll(.hidden)
                }
                Button("全部清空为未标") {
                    setAll(.unknown)
                }
                Button("复制上一份标签") {
                    copyPreviousLabels()
                }
                .disabled(snapshots.count < 2)
                if labels.autoCount > 0 {
                    Button("确认全部自动标注（\(labels.autoCount)）") {
                        confirmAllAutoLabels()
                    }
                    Button("清除自动标注（\(labels.autoCount)）") {
                        clearAutoLabels()
                    }
                }
            }
            .controlSize(.small)

            Text("标签只在本机保存；不会上传。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings & Actions

    private func stateBinding(label: SnapshotCellLabel) -> Binding<CellState> {
        Binding(
            get: { label.state },
            set: { newState in
                updateSelected { $0.setState(newState) }
            }
        )
    }

    private func colorBinding(label: SnapshotCellLabel) -> Binding<PieceColor> {
        Binding(
            get: { label.color ?? .red },
            set: { newColor in
                updateSelected { $0.setColor(newColor) }
            }
        )
    }

    private func pieceBinding(label: SnapshotCellLabel) -> Binding<String> {
        Binding(
            get: { label.piece ?? "" },
            set: { newPiece in
                updateSelected { $0.setPiece(newPiece.isEmpty ? nil : newPiece) }
            }
        )
    }

    private func updateSelected(_ transform: (inout SnapshotCellLabel) -> Void) {
        guard let summary = selectedSummary, var labels else { return }
        guard labels.update(index: selectedCell, transform) else { return }
        self.labels = labels
        persist(labels, summary: summary)
    }

    private func setAll(_ state: CellState) {
        guard let summary = selectedSummary, var labels else { return }
        labels.setAll(state)
        self.labels = labels
        persist(labels, summary: summary)
    }

    private func copyPreviousLabels() {
        guard let summary = selectedSummary,
              let index = snapshots.firstIndex(where: { $0.id == summary.id }),
              snapshots.indices.contains(index + 1)
        else {
            message = "没有更早的快照可复制"
            return
        }
        let source = snapshots[index + 1]
        guard hasLabels(source) else {
            message = "上一份快照还没有标签"
            return
        }
        do {
            guard let copied = try library.copyLabels(from: source, to: summary) else {
                message = "上一份快照没有标签"
                return
            }
            self.labels = copied
            persist(copied, summary: summary)
            message = "已复制 \(shortTimestamp(source.id)) 的标签"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func autoLabelAllPending() {
        let pending = snapshots.filter { summary in
            guard summary.isValidManifest else { return false }
            guard let existing = try? library.loadLabels(summary) else { return true }
            return existing.unknownCount > 0
        }
        guard !pending.isEmpty else {
            message = "没有需要自动标注的快照"
            return
        }
        runAutoLabel(on: pending)
    }

    private func runAutoLabel(on targets: [SnapshotSummary]) {
        guard !autoLabeling, !targets.isEmpty else { return }
        autoLabeling = true
        autoStatus = "准备中…"
        message = nil
        errorMessage = nil

        if targets.count == 1, let only = targets.first,
           let existing = try? library.loadLabels(only), existing.unknownCount == 0 {
            autoLabeling = false
            autoStatus = nil
            message = "这份快照已全部标完，没有需要自动标注的格子"
            return
        }

        let library = self.library
        let allSnapshots = self.snapshots
        let selectedID = self.selectedSnapshotID

        DispatchQueue.global(qos: .userInitiated).async {
            var totalFilled = 0
            var totalLeft = 0
            var reused = 0
            var modeled = 0
            var updated: [String: SnapshotLabels] = [:]
            var failed: [String] = []

            for (offset, summary) in targets.enumerated() {
                let prefix = targets.count > 1 ? "\(offset + 1)/\(targets.count) · " : ""
                DispatchQueue.main.async {
                    autoStatus = "\(prefix)\(summary.id)…"
                }
                do {
                    let manifest = try library.loadManifest(summary)
                    let base = try library.loadLabels(summary)
                        ?? SnapshotLabels(manifest: manifest, snapshot: summary.id)
                        ?? SnapshotLabels(
                            rows: manifest.rows,
                            cols: manifest.cols,
                            snapshot: summary.id
                        )

                    let outcome = try AutoLabeler.run(
                        target: summary,
                        manifest: manifest,
                        targetLabels: base,
                        allSnapshots: allSnapshots,
                        library: library,
                        progress: { text in
                            DispatchQueue.main.async {
                                autoStatus = prefix + text
                            }
                        }
                    )

                    // 期间可能有人工编辑，落盘前重读一次，只填仍是「未标」的格子。
                    var merged = (try? library.loadLabels(summary)) ?? base
                    for (index, decision) in outcome.decisions
                    where merged.label(at: index)?.state == .unknown {
                        merged.update(index: index) { label in
                            label.applyAuto(
                                state: decision.state,
                                color: decision.color,
                                piece: decision.piece
                            )
                        }
                    }
                    try library.saveLabels(merged, for: summary)

                    updated[summary.id] = merged
                    totalFilled += outcome.decisions.count
                    totalLeft += merged.unknownCount
                    reused += outcome.decisions.values.filter { $0.source == .previous }.count
                    modeled += outcome.decisions.values.filter { $0.source == .model }.count
                } catch {
                    failed.append("\(summary.id)：\(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async {
                autoLabeling = false
                autoStatus = nil
                if let selectedID, let value = updated[selectedID] {
                    labels = value
                }
                if totalFilled > 0 {
                    message = "自动填入 \(totalFilled) 格"
                        + "（沿用上一份 \(reused) · 模型 \(modeled)）"
                        + "，剩余未标 \(totalLeft) 格"
                } else {
                    message = "没有可自动确定的格子，需要人工标注"
                }
                if !failed.isEmpty {
                    errorMessage = "部分快照失败：" + failed.joined(separator: "；")
                }
            }
        }
    }

    private func confirmAllAutoLabels() {
        guard let summary = selectedSummary, var labels else { return }
        let count = labels.autoCount
        labels.confirmAllAuto()
        self.labels = labels
        persist(labels, summary: summary)
        message = "已确认 \(count) 个自动标注格"
    }

    private func clearAutoLabels() {
        guard let summary = selectedSummary, var labels else { return }
        labels.clearAuto()
        self.labels = labels
        persist(labels, summary: summary)
        message = "已把自动标注的格子退回未标"
    }

    private func persist(_ labels: SnapshotLabels, summary: SnapshotSummary) {
        do {
            try library.saveLabels(labels, for: summary)
            message = "标签已保存"
            errorMessage = nil
        } catch {
            errorMessage = "保存标签失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Loading

    private func reload() {
        do {
            snapshots = try library.list()
            errorMessage = nil
            if let selectedSnapshotID,
               let summary = snapshots.first(where: { $0.id == selectedSnapshotID }) {
                select(summary)
            } else if let first = snapshots.first {
                select(first)
            } else {
                selectedSnapshotID = nil
                manifest = nil
                labels = nil
                images = [:]
            }
        } catch {
            errorMessage = "读取样本目录失败：\(error.localizedDescription)"
        }
    }

    private func select(_ summary: SnapshotSummary) {
        selectedSnapshotID = summary.id
        selectedCell = 0
        message = nil
        errorMessage = nil

        guard summary.isValidManifest else {
            manifest = nil
            labels = nil
            images = [:]
            errorMessage = summary.manifestError
            return
        }

        do {
            let manifest = try library.loadManifest(summary)
            self.manifest = manifest
            if let existing = try library.loadLabels(summary) {
                labels = existing
            } else if let empty = SnapshotLabels(manifest: manifest, snapshot: summary.id) {
                labels = empty
            } else {
                labels = SnapshotLabels(
                    rows: manifest.rows,
                    cols: manifest.cols,
                    snapshot: summary.id
                )
            }

            var loaded: [Int: NSImage] = [:]
            for cell in manifest.cells {
                let url = library.imageURL(for: cell, in: summary)
                if let image = NSImage(contentsOf: url) {
                    loaded[cell.index] = image
                }
            }
            images = loaded
        } catch {
            manifest = nil
            labels = nil
            images = [:]
            errorMessage = "读取快照失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func borderColor(_ label: SnapshotCellLabel?) -> Color {
        guard let label else { return .secondary.opacity(0.35) }
        if label.auto == true { return .purple }
        switch label.state {
        case .unknown: return .secondary.opacity(0.35)
        case .empty: return .blue
        case .hidden: return .orange
        case .revealed:
            return label.color == .black ? .primary : .red
        }
    }

    private func hasLabels(_ summary: SnapshotSummary) -> Bool {
        FileManager.default.fileExists(atPath: library.labelsURL(for: summary).path)
    }

    private func shortTimestamp(_ id: String) -> String {
        id.hasPrefix("snapshot-") ? String(id.dropFirst("snapshot-".count)) : id
    }

    private func windowText(_ summary: SnapshotSummary) -> String {
        guard let size = summary.windowSize else { return "" }
        return " · \(Int(size.width))×\(Int(size.height))"
    }
}
