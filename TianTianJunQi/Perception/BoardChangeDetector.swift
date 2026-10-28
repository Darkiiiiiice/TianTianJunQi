import CoreGraphics
import CoreImage
import Foundation

/// 一张缩小后的棋盘画面指纹（RGBA，左上原点）。
/// 只用于「棋盘有没有变」的比较，不参与棋子识别。
struct BoardFingerprint: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

/// 指纹里的一格（probe 像素坐标，半开区间）。
/// 由 `BoardGrid.cellBoundingRects()` 的归一化矩形换算而来。
struct BoardCellBox: Equatable, Sendable {
    let row: Int
    let col: Int
    let x0: Int
    let y0: Int
    let x1: Int
    let y1: Int

    var isValid: Bool { x1 > x0 && y1 > y0 }
}

/// 一格的差异统计。
struct BoardCellDelta: Equatable, Sendable {
    let row: Int
    let col: Int
    /// 格内单通道差值 > `pixelDelta` 的像素占比（0…1）。
    let fraction: Double
    /// 格内单通道差值的平均值（0…255）。比 `fraction` 更能区分
    /// 「细边框发光」和「整张棋子换了」。
    let meanDelta: Double

    var id: BoardCellID { BoardCellID(row: row, col: col) }

    /// 是否像「棋子本体变了」：整格大范围、大幅度变化。
    ///
    /// 实测（真机 368×251、probe 宽 240）：
    /// - 真走棋/翻棋：占比 79%–99%，平均差 45–100；
    /// - 上一步棋子的选中框/闪光泽：占比 ≤31%，平均差 ≈12。
    /// 所以两个条件都给足余量，选中框与走法箭头不会被当成一步棋。
    func isPieceChange(minFraction: Double, minMeanDelta: Double) -> Bool {
        fraction >= minFraction && meanDelta >= minMeanDelta
    }
}

extension BoardCellBox {
    /// 把归一化格子矩形换算成 probe 像素格（行优先）。
    static func grid(
        rows: Int,
        cols: Int,
        rects: [CGRect],
        probeWidth: Int,
        probeHeight: Int
    ) -> [BoardCellBox] {
        guard rows > 0, cols > 0, rects.count == rows * cols,
              probeWidth > 1, probeHeight > 1
        else { return [] }

        return rects.enumerated().compactMap { index, rect -> BoardCellBox? in
            let standardized = rect.standardized
            guard standardized.width > 0, standardized.height > 0 else { return nil }
            // 用四舍五入而不是 floor/ceil：否则相邻格会在边界上多算一行/列，
            // 一格变化会被记到邻格头上。
            let x0 = max(0, min(probeWidth, Int((standardized.minX * CGFloat(probeWidth)).rounded())))
            let x1 = max(0, min(probeWidth, Int((standardized.maxX * CGFloat(probeWidth)).rounded())))
            let y0 = max(0, min(probeHeight, Int((standardized.minY * CGFloat(probeHeight)).rounded())))
            let y1 = max(0, min(probeHeight, Int((standardized.maxY * CGFloat(probeHeight)).rounded())))
            let box = BoardCellBox(
                row: index / cols,
                col: index % cols,
                x0: x0,
                y0: y0,
                x1: x1,
                y1: y1
            )
            return box.isValid ? box : nil
        }
    }
}

/// 棋盘变化检测（纯函数，便于单测与回放）。
///
/// 两级信号：
/// 1. `changedFraction`：整块棋盘区域的变化比例，用来判断「还在动还是停了」；
/// 2. `cellDeltas`：逐格变化比例与平均差，用来判断「是不是棋子本体变了」。
///
/// 只看整盘比例会被选中框/高光闪烁干扰（它们能占到 0.6% 棋盘面积），
/// 而逐格看时真实走棋与闪烁差 3–8 倍。
enum BoardChangeDetector {
    /// 指纹固定宽度；高度按内容宽高比推导（同一窗口尺寸下稳定）。
    static let defaultWidth = 240

    nonisolated private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 把任意 CI 图缩成指纹。`image` 的 extent 原点会先归零。
    static func fingerprint(image: CIImage, width: Int = defaultWidth) -> BoardFingerprint? {
        guard width > 1 else { return nil }
        let extent = image.extent
        guard extent.width > 8, extent.height > 8, extent.isInfinite == false else {
            return nil
        }

        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        let height = max(8, Int((extent.height / extent.width * CGFloat(width)).rounded()))
        let scaled = normalized.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / extent.width,
                y: CGFloat(height) / extent.height
            )
        )

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            ciContext.render(
                scaled,
                toBitmap: base,
                rowBytes: width * 4,
                bounds: bounds,
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }
        return BoardFingerprint(width: width, height: height, pixels: pixels)
    }

    /// 两张指纹在棋盘外接矩形内的差异比例（0…1）。
    /// 尺寸不一致（窗口宽高比变了）返回 nil，由调用方重置基线。
    /// `pixelDelta` 是单通道差值阈值，用来忽略压缩/抗锯齿噪声。
    static func changedFraction(
        _ lhs: BoardFingerprint,
        _ rhs: BoardFingerprint,
        boardCorners: [CGPoint],
        pixelDelta: Int = 20
    ) -> Double? {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              lhs.width > 0, lhs.height > 0,
              lhs.pixels.count == rhs.pixels.count,
              boardCorners.count >= 3
        else { return nil }

        let xs = boardCorners.map(\.x)
        let ys = boardCorners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return nil }

        let width = lhs.width
        let height = lhs.height
        let x0 = max(0, min(width, Int((minX * CGFloat(width)).rounded(.down))))
        let x1 = max(0, min(width, Int((maxX * CGFloat(width)).rounded(.up))))
        let y0 = max(0, min(height, Int((minY * CGFloat(height)).rounded(.down))))
        let y1 = max(0, min(height, Int((maxY * CGFloat(height)).rounded(.up))))
        guard x1 > x0, y1 > y0 else { return nil }

        var changed = 0
        var total = 0
        lhs.pixels.withUnsafeBufferPointer { a in
            rhs.pixels.withUnsafeBufferPointer { b in
                for y in y0..<y1 {
                    let row = y * width * 4
                    for x in x0..<x1 {
                        let offset = row + x * 4
                        let dr = Int(a[offset]) - Int(b[offset])
                        let dg = Int(a[offset + 1]) - Int(b[offset + 1])
                        let db = Int(a[offset + 2]) - Int(b[offset + 2])
                        let delta = max(abs(dr), max(abs(dg), abs(db)))
                        if delta > pixelDelta { changed += 1 }
                        total += 1
                    }
                }
            }
        }
        guard total > 0 else { return nil }
        return Double(changed) / Double(total)
    }

    /// 逐格差异统计。`boxes` 来自 `BoardGrid.cellBoundingRects()`。
    /// 尺寸不一致或格为空时返回空数组，由调用方按「没有棋子变化」处理。
    static func cellDeltas(
        _ lhs: BoardFingerprint,
        _ rhs: BoardFingerprint,
        boxes: [BoardCellBox],
        pixelDelta: Int = 20
    ) -> [BoardCellDelta] {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              lhs.width > 0, lhs.height > 0,
              lhs.pixels.count == rhs.pixels.count,
              !boxes.isEmpty
        else { return [] }

        let width = lhs.width
        return lhs.pixels.withUnsafeBufferPointer { a in
            rhs.pixels.withUnsafeBufferPointer { b in
                boxes.compactMap { box -> BoardCellDelta? in
                    guard box.isValid,
                          box.x0 >= 0, box.y0 >= 0,
                          box.x1 <= lhs.width, box.y1 <= lhs.height
                    else { return nil }

                    var changed = 0
                    var total = 0
                    var sum = 0
                    for y in box.y0..<box.y1 {
                        let row = y * width * 4
                        for x in box.x0..<box.x1 {
                            let offset = row + x * 4
                            let dr = abs(Int(a[offset]) - Int(b[offset]))
                            let dg = abs(Int(a[offset + 1]) - Int(b[offset + 1]))
                            let db = abs(Int(a[offset + 2]) - Int(b[offset + 2]))
                            let delta = max(dr, max(dg, db))
                            if delta > pixelDelta { changed += 1 }
                            sum += delta
                            total += 1
                        }
                    }
                    guard total > 0 else { return nil }
                    return BoardCellDelta(
                        row: box.row,
                        col: box.col,
                        fraction: Double(changed) / Double(total),
                        meanDelta: Double(sum) / Double(total)
                    )
                }
            }
        }
    }
}
