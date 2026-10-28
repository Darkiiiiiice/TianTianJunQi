import CoreGraphics
import Foundation
import ImageIO
import Vision

/// 一格自动标注结果。
struct AutoLabelDecision: Equatable, Sendable {
    enum Source: String, Sendable {
        /// 与上一份快照同一格像素完全一致，直接沿用它的标签。
        case previous
        /// 用已标注样本做特征近邻投票。
        case model
    }

    var state: CellState
    var color: PieceColor?
    var piece: String?
    var source: Source
    var votes: Int
    var total: Int
}

struct AutoLabelOutcome: Sendable {
    var decisions: [Int: AutoLabelDecision]
    var referenceCount: Int
    var uniqueReferenceImages: Int
    var elapsed: TimeInterval
}

enum AutoLabelerError: LocalizedError {
    case noReference
    case noCells

    var errorDescription: String? {
        switch self {
        case .noReference:
            "还没有可用的人工标注样本，先手工标一份再自动标注"
        case .noCells:
            "这份快照没有「未标」的格子"
        }
    }
}

/// M1-3 自动标注：用已标注样本给新快照预填，无法确定的格子留空。
///
/// 两级策略：
/// 1. 同一格与上一份快照像素完全一致 → 直接抄它的标签（同局连续采集最常见）；
/// 2. 其余格子用 Vision feature print 做近邻投票，票数不够就不填。
enum AutoLabeler {
    // MARK: - 对外入口

    static func run(
        target: SnapshotSummary,
        manifest: BoardSnapshotManifest,
        targetLabels: SnapshotLabels,
        allSnapshots: [SnapshotSummary],
        library: SnapshotLibrary,
        progress: ((String) -> Void)? = nil
    ) throws -> AutoLabelOutcome {
        let started = Date()
        let pending = manifest.cells.filter {
            targetLabels.label(at: $0.index)?.state == .unknown
        }
        guard !pending.isEmpty else { throw AutoLabelerError.noCells }

        progress?("读取已标注样本…")
        // 只用比目标更早的已标注快照，避免「未来数据」造成评估虚高。
        let reference = try buildReference(
            snapshots: allSnapshots.filter { $0.id < target.id },
            library: library,
            progress: progress
        )
        guard !reference.entries.isEmpty else { throw AutoLabelerError.noReference }

        let previous = previousLabeled(
            before: target,
            snapshots: allSnapshots,
            library: library
        )

        var decisions: [Int: AutoLabelDecision] = [:]
        var counters = (total: 0, previous: 0, model: 0)

        for (offset, cell) in pending.enumerated() {
            counters.total += 1
            if offset % 10 == 0 {
                progress?("识别 \(offset + 1)/\(pending.count)…")
            }

            let url = library.imageURL(for: cell, in: target)

            // 1. 同格像素完全一致：直接沿用上一份标签。
            if let previous,
               let copied = copiedLabel(for: cell, from: previous, target: target, library: library) {
                decisions[cell.index] = copied
                counters.previous += 1
                continue
            }

            // 2. 特征近邻投票。参考库里几乎没见过明子时，近邻会把明子误判成暗子，
            //    这种情况只保留第 1 级（同格照抄），其余留空。
            guard reference.revealedCount >= 10 else { continue }
            guard let loaded = FeaturePrintCache.shared.print(for: url),
                  let image = loadImage(url)
            else { continue }
            guard let stateVote = AutoLabelVote.winner(
                reference.entries.map { (label: $0.state, distance: distance(loaded.observation, $0.print)) },
                k: 7,
                minVotes: 5
            ) else { continue }

            let analysis = analyze(image)
            // 棋子上有白色字 → 一定是明子。参考库里还没有明子时，近邻会把它误投成暗子。
            if analysis.whiteRatio > 0.005, stateVote.label != .revealed {
                continue
            }

            switch stateVote.label {
            case .unknown:
                continue

            case .empty, .hidden:
                decisions[cell.index] = AutoLabelDecision(
                    state: stateVote.label,
                    color: nil,
                    piece: nil,
                    source: .model,
                    votes: stateVote.votes,
                    total: stateVote.total
                )
                counters.model += 1

            case .revealed:
                guard let color = analysis.color else { continue }
                let pool = reference.entries.filter {
                    $0.state == .revealed && $0.color == color && $0.piece != nil
                }
                // 参考库按图片去重后冷门棋子只有几张图，不能再用「至少 4 张」把整类挡掉。
                guard !pool.isEmpty,
                      let pieceVote = AutoLabelVote.piece(
                          pool.map { (label: $0.piece!, distance: distance(loaded.observation, $0.print)) },
                          k: 5
                      )
                else { continue }
                decisions[cell.index] = AutoLabelDecision(
                    state: .revealed,
                    color: color,
                    piece: pieceVote.label,
                    source: .model,
                    votes: pieceVote.votes,
                    total: pieceVote.total
                )
                counters.model += 1
            }
        }

        progress?("完成：自动填 \(decisions.count) 格，留空 \(pending.count - decisions.count) 格")
        return AutoLabelOutcome(
            decisions: decisions,
            referenceCount: reference.entries.count,
            uniqueReferenceImages: reference.uniqueImages,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    // MARK: - 参考库

    private struct ReferenceEntry {
        let state: CellState
        let color: PieceColor?
        let piece: String?
        let print: VNFeaturePrintObservation
    }

    private struct Reference {
        let entries: [ReferenceEntry]
        let uniqueImages: Int
        let revealedCount: Int
    }

    private static func buildReference(
        snapshots: [SnapshotSummary],
        library: SnapshotLibrary,
        progress: ((String) -> Void)?
    ) throws -> Reference {
        let summaries = snapshots.filter(\.isValidManifest)

        var entries: [ReferenceEntry] = []
        var seen = Set<String>()
        var uniqueImages = 0
        var revealedCount = 0
        var visited = 0

        for summary in summaries {
            guard let labels = try? library.loadLabels(summary),
                  let manifest = try? library.loadManifest(summary)
            else { continue }

            for cell in manifest.cells {
                guard let label = labels.label(at: cell.index),
                      label.isComplete,
                      label.auto != true
                else { continue }

                visited += 1
                if visited % 40 == 0 {
                    progress?("建立参考库 \(visited) 格…")
                }

                let url = library.imageURL(for: cell, in: summary)
                guard let loaded = FeaturePrintCache.shared.print(for: url) else { continue }
                let key = "\(loaded.key)-\(label.state.rawValue)-\(label.color?.rawValue ?? "")-\(label.piece ?? "")"
                guard seen.insert(key).inserted else { continue }

                uniqueImages += 1
                if label.state == .revealed { revealedCount += 1 }
                entries.append(
                    ReferenceEntry(
                        state: label.state,
                        color: label.color,
                        piece: label.piece,
                        print: loaded.observation
                    )
                )
            }
        }
        return Reference(
            entries: entries,
            uniqueImages: uniqueImages,
            revealedCount: revealedCount
        )
    }

    // MARK: - 上一份快照

    private struct PreviousSnapshot {
        let summary: SnapshotSummary
        let manifest: BoardSnapshotManifest
        let labels: SnapshotLabels
    }

    private static func previousLabeled(
        before target: SnapshotSummary,
        snapshots: [SnapshotSummary],
        library: SnapshotLibrary
    ) -> PreviousSnapshot? {
        guard let index = snapshots.firstIndex(where: { $0.id == target.id }) else { return nil }
        for candidate in snapshots.dropFirst(index + 1) {
            guard candidate.isValidManifest,
                  candidate.rows == target.rows,
                  candidate.cols == target.cols,
                  let labels = try? library.loadLabels(candidate),
                  labels.isValid,
                  let manifest = try? library.loadManifest(candidate)
            else { continue }
            return PreviousSnapshot(summary: candidate, manifest: manifest, labels: labels)
        }
        return nil
    }

    /// 同一格图片字节一致时，复制上一份的完整标签。
    private static func copiedLabel(
        for cell: BoardSnapshotManifest.Cell,
        from previous: PreviousSnapshot,
        target: SnapshotSummary,
        library: SnapshotLibrary
    ) -> AutoLabelDecision? {
        guard let oldCell = previous.manifest.cells.first(where: { $0.index == cell.index }),
              let oldLabel = previous.labels.label(at: oldCell.index),
              oldLabel.isComplete
        else { return nil }

        let newURL = library.imageURL(for: cell, in: target)
        let oldURL = library.imageURL(for: oldCell, in: previous.summary)
        guard let newData = try? Data(contentsOf: newURL),
              let oldData = try? Data(contentsOf: oldURL),
              newData == oldData
        else { return nil }

        return AutoLabelDecision(
            state: oldLabel.state,
            color: oldLabel.color,
            piece: oldLabel.piece,
            source: .previous,
            votes: 1,
            total: 1
        )
    }

    // MARK: - 图像工具

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func distance(
        _ lhs: VNFeaturePrintObservation,
        _ rhs: VNFeaturePrintObservation
    ) -> Float {
        var value: Float = .greatestFiniteMagnitude
        try? lhs.computeDistance(&value, to: rhs)
        return value
    }

    private struct ImageStats {
        let color: PieceColor?
        /// 近白像素占比：明子的白色字 ≥1%，空/暗子实测为 0。
        let whiteRatio: Double
    }

    /// 红/黑底色 + 白字占比。实测红方 r−b ≈ +92、黑方 ≈ −42，留了大余量。
    private static func analyze(_ image: CGImage) -> ImageStats {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return ImageStats(color: nil, whiteRatio: 0)
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        var red = 0.0
        var blue = 0.0
        var white = 0
        for index in 0..<(size * size) {
            let r = Double(pixels[index * 4])
            let g = Double(pixels[index * 4 + 1])
            let b = Double(pixels[index * 4 + 2])
            red += r
            blue += b
            if r > 200, g > 200, b > 200 {
                white += 1
            }
        }
        let count = Double(size * size)
        let diff = (red - blue) / count
        let color: PieceColor? = diff > 20 ? .red : (diff < -20 ? .black : nil)
        return ImageStats(color: color, whiteRatio: Double(white) / count)
    }

    // MARK: - 特征缓存

    /// 按图片字节去重后缓存 feature print：同一颗棋子坐着不动时只算一次。
    private final class FeaturePrintCache {
        static let shared = FeaturePrintCache()

        private var storage: [Int: VNFeaturePrintObservation] = [:]
        private let lock = NSLock()

        func print(for url: URL) -> (observation: VNFeaturePrintObservation, key: Int)? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let key = data.hashValue

            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[key] {
                return (cached, key)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let observation = Self.compute(image)
            else { return nil }
            storage[key] = observation
            return (observation, key)
        }

        private static func compute(_ image: CGImage) -> VNFeaturePrintObservation? {
            let request = VNGenerateImageFeaturePrintRequest()
            request.imageCropAndScaleOption = .centerCrop
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
            return request.results?.first
        }
    }
}
