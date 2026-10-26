import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum BoardSnapshotError: LocalizedError {
    case invalidFrame
    case cellRenderFailed(row: Int, col: Int)
    case pngWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFrame:
            "抓帧内容区为空，无法采集样本"
        case .cellRenderFailed(let row, let col):
            "格子 (\(row), \(col)) 透视裁剪失败"
        case .pngWriteFailed(let path):
            "写入 PNG 失败：\(path)"
        }
    }
}

/// 一次棋盘采样的元数据。格子图片按 row/col 命名，标签由后续标注流程补。
struct BoardSnapshotManifest: Codable, Sendable {
    struct Cell: Codable, Sendable {
        let index: Int
        let row: Int
        let col: Int
        /// 相对 snapshot 目录。
        let file: String
        /// 格心（归一化，左上原点）。
        let center: CGPoint
    }

    let createdAt: Date
    let rows: Int
    let cols: Int
    let windowSize: CGSize?
    let theme: String?
    let frameFile: String
    let cellSize: Int
    let boardCorners: [CGPoint]
    let contentPixelSize: CGSize
    let cells: [Cell]
}

/// 棋盘样本导出（M1-3 数据采集 / M2-7 关键帧落盘）：
/// 保存整帧、60 个透视校正后的格子图与 meta.json，供后续分类器训练与回放。
struct BoardSnapshotExporter {
    var rootURL: URL = StorageKit().samplesURL
    /// 每格输出边长（像素）。
    var cellSize = 128
    /// 每格四周内缩比例（0..0.5），避开格线/相邻格。
    var inset: CGFloat = 0.04

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    @discardableResult
    func export(
        frame: CapturedFrame,
        grid: BoardGrid,
        windowSize: CGSize?,
        theme: String?
    ) throws -> URL {
        let content = try Self.contentImage(from: frame)
        let width = content.extent.width
        let height = content.extent.height
        guard width > 8, height > 8 else { throw BoardSnapshotError.invalidFrame }

        let directory = rootURL.appendingPathComponent(
            "snapshot-\(Self.folderTimestamp(Date()))",
            isDirectory: true
        )
        let cellsDirectory = directory.appendingPathComponent("cells", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cellsDirectory, withIntermediateDirectories: true
        )

        let frameFile = "frame.png"
        try Self.writePNG(content, to: directory.appendingPathComponent(frameFile))

        var records: [BoardSnapshotManifest.Cell] = []
        records.reserveCapacity(grid.rows * grid.cols)

        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let index = row * grid.cols + col
                let u0 = (CGFloat(col) + inset) / CGFloat(grid.cols)
                let u1 = (CGFloat(col + 1) - inset) / CGFloat(grid.cols)
                let v0 = (CGFloat(row) + inset) / CGFloat(grid.rows)
                let v1 = (CGFloat(row + 1) - inset) / CGFloat(grid.rows)

                let topLeft = Self.pixelPoint(
                    grid.point(u: u0, v: v0), width: width, height: height
                )
                let topRight = Self.pixelPoint(
                    grid.point(u: u1, v: v0), width: width, height: height
                )
                let bottomLeft = Self.pixelPoint(
                    grid.point(u: u0, v: v1), width: width, height: height
                )
                let bottomRight = Self.pixelPoint(
                    grid.point(u: u1, v: v1), width: width, height: height
                )

                guard let cell = Self.rectify(
                    content,
                    topLeft: topLeft,
                    topRight: topRight,
                    bottomLeft: bottomLeft,
                    bottomRight: bottomRight,
                    size: cellSize
                ) else {
                    throw BoardSnapshotError.cellRenderFailed(row: row, col: col)
                }

                let file = String(format: "cells/r%02dc%02d.png", row, col)
                try Self.writePNG(cell, to: directory.appendingPathComponent(file))
                records.append(
                    BoardSnapshotManifest.Cell(
                        index: index,
                        row: row,
                        col: col,
                        file: file,
                        center: grid.cellCenters[index]
                    )
                )
            }
        }

        let manifest = BoardSnapshotManifest(
            createdAt: Date(),
            rows: grid.rows,
            cols: grid.cols,
            windowSize: windowSize,
            theme: theme,
            frameFile: frameFile,
            cellSize: cellSize,
            boardCorners: grid.quad.corners,
            contentPixelSize: CGSize(width: width, height: height),
            cells: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(
            to: directory.appendingPathComponent("meta.json"), options: .atomic
        )
        return directory
    }

    // MARK: - Rendering

    /// 与预览/OCR 相同的裁剪方式，并把 extent 平移到 (0,0)。
    private static func contentImage(from frame: CapturedFrame) throws -> CIImage {
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let extent = source.extent
        guard extent.width > 8, extent.height > 8 else {
            throw BoardSnapshotError.invalidFrame
        }

        let content = frame.contentRect
        let crop = content == CapturedFrame.fullFrame
            ? extent
            : CGRect(
                x: extent.minX + content.minX * extent.width,
                y: extent.minY + content.minY * extent.height,
                width: content.width * extent.width,
                height: content.height * extent.height
            )
        let cropped = source.cropped(to: crop)
        return cropped.transformed(
            by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        )
    }

    /// 左上原点归一化坐标 → CIImage 像素坐标（CI 原点在左下）。
    private static func pixelPoint(
        _ point: CGPoint,
        width: CGFloat,
        height: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x * width, y: (1 - point.y) * height)
    }

    /// 用透视校正把任意四边形格子拉成固定尺寸的正方形。
    private static func rectify(
        _ image: CIImage,
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomLeft: CGPoint,
        bottomRight: CGPoint,
        size: Int
    ) -> CGImage? {
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

        guard let output = filter.outputImage else { return nil }
        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scaled = output.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(size) / extent.width,
                y: CGFloat(size) / extent.height
            )
        )
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }

    private static func writePNG(_ image: CIImage, to url: URL) throws {
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            throw BoardSnapshotError.pngWriteFailed(url.path)
        }
        try writePNG(cgImage, to: url)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw BoardSnapshotError.pngWriteFailed(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BoardSnapshotError.pngWriteFailed(url.path)
        }
    }

    private static func folderTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}
