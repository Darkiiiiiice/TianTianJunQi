import CoreGraphics
import Foundation

/// 单格人工标签（M1-3 标注）。与 `CellObservation` 的区别是不带置信度，
/// 并且允许暂时不完整（明子还没选颜色/棋子名）。
struct SnapshotCellLabel: Codable, Equatable, Sendable, Identifiable {
    let index: Int
    let row: Int
    let col: Int
    var state: CellState
    var color: PieceColor?
    var piece: String?

    var id: Int { index }

    init(
        index: Int,
        row: Int,
        col: Int,
        state: CellState = .unknown,
        color: PieceColor? = nil,
        piece: String? = nil
    ) {
        self.index = index
        self.row = row
        self.col = col
        self.state = state
        self.color = color
        self.piece = piece
        normalize()
    }

    var isComplete: Bool {
        switch state {
        case .empty, .hidden: true
        case .unknown: false
        case .revealed:
            color != nil && piece?.isEmpty == false && PieceCatalog.isValid(piece ?? "")
        }
    }

    var displayLabel: String {
        switch state {
        case .unknown: return "未标"
        case .empty: return "空"
        case .hidden: return "暗"
        case .revealed:
            let colorText = color == .red ? "红" : (color == .black ? "黑" : "?")
            return "\(colorText)\(piece ?? "?")"
        }
    }

    mutating func setState(_ newState: CellState) {
        state = newState
        if newState == .revealed, color == nil {
            color = .red
        }
        normalize()
    }

    mutating func setColor(_ newColor: PieceColor?) {
        color = newColor
        normalize()
    }

    mutating func setPiece(_ newPiece: String?) {
        piece = newPiece?.trimmingCharacters(in: .whitespacesAndNewlines)
        normalize()
    }

    /// 非明子清空颜色/棋子；明子只保留合法棋子名。
    private mutating func normalize() {
        switch state {
        case .empty, .hidden, .unknown:
            color = nil
            piece = nil
        case .revealed:
            if let value = piece, !PieceCatalog.isValid(value) {
                piece = nil
            }
        }
    }
}

/// 一份快照的 labels.json：与 meta.json 的 60 格一一对应。
struct SnapshotLabels: Codable, Equatable, Sendable {
    var version: Int = 1
    var snapshot: String
    var rows: Int
    var cols: Int
    var updatedAt: Date
    var cells: [SnapshotCellLabel]

    init(rows: Int, cols: Int, snapshot: String, date: Date = Date()) {
        self.snapshot = snapshot
        self.rows = rows
        self.cols = cols
        self.updatedAt = date
        self.cells = (0..<(rows * cols)).map { index in
            SnapshotCellLabel(
                index: index,
                row: index / max(cols, 1),
                col: index % max(cols, 1)
            )
        }
    }

    init?(manifest: BoardSnapshotManifest, snapshot: String, date: Date = Date()) {
        guard manifest.rows > 0, manifest.cols > 0,
              manifest.cells.count == manifest.rows * manifest.cols
        else { return nil }
        self.snapshot = snapshot
        self.rows = manifest.rows
        self.cols = manifest.cols
        self.updatedAt = date
        self.cells = manifest.cells
            .sorted { $0.index < $1.index }
            .map { cell in
                SnapshotCellLabel(index: cell.index, row: cell.row, col: cell.col)
            }
    }

    var isValid: Bool {
        version == 1
            && rows > 0
            && cols > 0
            && cells.count == rows * cols
            && cells.enumerated().allSatisfy { pair in
                let (offset, cell) = pair
                return cell.index == offset
                    && cell.row == offset / cols
                    && cell.col == offset % cols
            }
    }

    var isComplete: Bool { cells.allSatisfy(\.isComplete) }

    var completeCount: Int { cells.filter(\.isComplete).count }
    var incompleteCount: Int { cells.count - completeCount }

    func label(at index: Int) -> SnapshotCellLabel? {
        guard cells.indices.contains(index) else { return nil }
        return cells[index]
    }

    @discardableResult
    mutating func update(index: Int, _ transform: (inout SnapshotCellLabel) -> Void) -> Bool {
        guard cells.indices.contains(index) else { return false }
        transform(&cells[index])
        updatedAt = Date()
        return true
    }

    mutating func setAll(_ state: CellState) {
        for index in cells.indices {
            cells[index].setState(state)
        }
        updatedAt = Date()
    }

    /// 同尺寸快照之间复制标签；棋盘尺寸不同则返回 nil。
    func copied(to snapshot: String, date: Date = Date()) -> SnapshotLabels? {
        SnapshotLabels(
            rows: rows,
            cols: cols,
            snapshot: snapshot,
            date: date,
            cells: cells
        )
    }

    private init(rows: Int, cols: Int, snapshot: String, date: Date, cells: [SnapshotCellLabel]) {
        self.snapshot = snapshot
        self.rows = rows
        self.cols = cols
        self.updatedAt = date
        self.cells = cells
    }
}

struct SnapshotSummary: Identifiable, Equatable, Sendable {
    /// 目录名，例如 `snapshot-20261026-114442-798`。
    let id: String
    let url: URL
    let createdAt: Date?
    let rows: Int?
    let cols: Int?
    let windowSize: CGSize?
    let theme: String?
    let manifestError: String?

    var cellCount: Int { (rows ?? 0) * (cols ?? 0) }
    var isValidManifest: Bool { manifestError == nil && (rows ?? 0) > 0 && (cols ?? 0) > 0 }
}

enum SnapshotLibraryError: LocalizedError {
    case manifestMissing(URL)
    case invalidLabels(String)
    case dimensionsMismatch(String)

    var errorDescription: String? {
        switch self {
        case .manifestMissing(let url):
            "缺少 meta.json：\(url.path)"
        case .invalidLabels(let reason):
            "标签文件无效：\(reason)"
        case .dimensionsMismatch(let reason):
            "棋盘尺寸不匹配：\(reason)"
        }
    }
}

/// 样本库读写（M1-3 标注）：扫描 `perception/samples`、读取 meta、保存 labels.json。
struct SnapshotLibrary {
    let rootURL: URL

    init(rootURL: URL = StorageKit().samplesURL) {
        self.rootURL = rootURL
    }

    func list() throws -> [SnapshotSummary] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.lastPathComponent.hasPrefix("snapshot-") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { url in
                let id = url.lastPathComponent
                do {
                    let manifest = try loadManifest(at: url)
                    return SnapshotSummary(
                        id: id,
                        url: url,
                        createdAt: manifest.createdAt,
                        rows: manifest.rows,
                        cols: manifest.cols,
                        windowSize: manifest.windowSize,
                        theme: manifest.theme,
                        manifestError: nil
                    )
                } catch {
                    return SnapshotSummary(
                        id: id,
                        url: url,
                        createdAt: nil,
                        rows: nil,
                        cols: nil,
                        windowSize: nil,
                        theme: nil,
                        manifestError: error.localizedDescription
                    )
                }
            }
            .sorted { $0.id > $1.id }
    }

    func loadManifest(_ summary: SnapshotSummary) throws -> BoardSnapshotManifest {
        try loadManifest(at: summary.url)
    }

    func loadLabels(_ summary: SnapshotSummary) throws -> SnapshotLabels? {
        let url = labelsURL(for: summary)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let labels = try decoder.decode(SnapshotLabels.self, from: Data(contentsOf: url))
        guard labels.isValid else {
            throw SnapshotLibraryError.invalidLabels("格数与行列不一致")
        }
        return labels
    }

    /// 保存标签；尺寸必须与该快照的 meta.json 一致。
    func saveLabels(_ labels: SnapshotLabels, for summary: SnapshotSummary) throws {
        guard labels.isValid else {
            throw SnapshotLibraryError.invalidLabels("格数与行列不一致")
        }
        let manifest = try loadManifest(summary)
        guard labels.rows == manifest.rows, labels.cols == manifest.cols else {
            throw SnapshotLibraryError.dimensionsMismatch(
                "\(labels.rows)×\(labels.cols) ≠ \(manifest.rows)×\(manifest.cols)"
            )
        }

        var value = labels
        value.snapshot = summary.id
        value.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: labelsURL(for: summary), options: .atomic)
    }

    /// 复制另一份同尺寸快照的标签（不落盘，由 UI 确认后保存）。
    func copyLabels(from source: SnapshotSummary, to destination: SnapshotSummary) throws -> SnapshotLabels? {
        guard let sourceLabels = try loadLabels(source) else { return nil }
        guard let destinationManifest = try? loadManifest(destination),
              destinationManifest.rows == sourceLabels.rows,
              destinationManifest.cols == sourceLabels.cols
        else {
            throw SnapshotLibraryError.dimensionsMismatch("来源与目标快照尺寸不同")
        }
        return sourceLabels.copied(to: destination.id)
    }

    func imageURL(for cell: BoardSnapshotManifest.Cell, in summary: SnapshotSummary) -> URL {
        summary.url.appendingPathComponent(cell.file)
    }

    func labelsURL(for summary: SnapshotSummary) -> URL {
        summary.url.appendingPathComponent("labels.json")
    }

    func manifestURL(for summary: SnapshotSummary) -> URL {
        summary.url.appendingPathComponent("meta.json")
    }

    private func loadManifest(at url: URL) throws -> BoardSnapshotManifest {
        let manifestURL = url.appendingPathComponent("meta.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SnapshotLibraryError.manifestMissing(manifestURL)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BoardSnapshotManifest.self, from: Data(contentsOf: manifestURL))
    }
}
