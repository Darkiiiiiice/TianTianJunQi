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
    /// 采集来源："auto" = 对局中棋盘变化后自动采样；nil/"manual" = 手动采集。
    /// 旧快照没有该字段，解码为 nil。
    var origin: String? = nil
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
        theme: String?,
        origin: String? = nil
    ) throws -> URL {
        let content = try Self.contentImage(from: frame)
        let width = content.extent.width
        let height = content.extent.height
        guard width > 8, height > 8 else { throw BoardSnapshotError.invalidFrame }

        let directory = Self.uniqueDirectory(in: rootURL)
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
                guard let cell = Self.renderCell(
                    content,
                    grid: grid,
                    row: row,
                    col: col,
                    size: cellSize,
                    inset: inset,
                    width: width,
                    height: height
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
            cells: records,
            origin: origin
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

    /// 内存版格子切图（行优先，索引 = row * cols + col），不落盘。
    ///
    /// 供 M1-4 实时感知直接喂 Core ML。参数必须与 `export` 保持一致
    /// （`inset 0.04` / `cellSize 128`），否则会出现训练/推理口径偏移。
    static func cellImages(
        from frame: CapturedFrame,
        grid: BoardGrid,
        cellSize: Int = 128,
        inset: CGFloat = 0.04
    ) throws -> [CGImage] {
        let content = try contentImage(from: frame)
        let width = content.extent.width
        let height = content.extent.height
        guard width > 8, height > 8 else { throw BoardSnapshotError.invalidFrame }

        var images: [CGImage] = []
        images.reserveCapacity(grid.rows * grid.cols)
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                guard let cell = renderCell(
                    content,
                    grid: grid,
                    row: row,
                    col: col,
                    size: cellSize,
                    inset: inset,
                    width: width,
                    height: height
                ) else {
                    throw BoardSnapshotError.cellRenderFailed(row: row, col: col)
                }
                images.append(cell)
            }
        }
        return images
    }

    /// M1-9：直接渲染成 Core ML 输入尺寸的 CVPixelBuffer。
    ///
    /// 与 `cellImages` 共用透视校正几何，但跳过 CGImage，喂给
    /// `MLFeatureValue(pixelBuffer:)` 时不再做一次图像转换。
    static func cellPixelBuffers(
        from frame: CapturedFrame,
        grid: BoardGrid,
        cellSize: Int = 128,
        inset: CGFloat = 0.04
    ) throws -> [CVPixelBuffer] {
        let content = try contentImage(from: frame)
        let width = content.extent.width
        let height = content.extent.height
        guard width > 8, height > 8 else { throw BoardSnapshotError.invalidFrame }

        var buffers: [CVPixelBuffer] = []
        buffers.reserveCapacity(grid.rows * grid.cols)
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                guard let buffer = PixelBufferRenderer.make(
                    width: cellSize,
                    height: cellSize
                ) else {
                    throw BoardSnapshotError.cellRenderFailed(row: row, col: col)
                }
                guard renderCell(
                    content,
                    grid: grid,
                    row: row,
                    col: col,
                    size: cellSize,
                    inset: inset,
                    width: width,
                    height: height,
                    into: buffer
                ) else {
                    throw BoardSnapshotError.cellRenderFailed(row: row, col: col)
                }
                buffers.append(buffer)
            }
        }
        return buffers
    }

    /// 按行列取一格的透视校正图；export 与内存切图共用这一处几何。
    private static func renderCell(
        _ content: CIImage,
        grid: BoardGrid,
        row: Int,
        col: Int,
        size: Int,
        inset: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> CGImage? {
        guard let output = rectifiedImage(
            content,
            grid: grid,
            row: row,
            col: col,
            size: size,
            inset: inset,
            width: width,
            height: height
        ) else { return nil }
        // CI 的 extent 常带浮点误差（例如 128.00000000000003），
        // createCGImage 会向上取整成 129px；显式裁到整数尺寸保证训练输入一致。
        let target = CGRect(
            x: output.extent.minX,
            y: output.extent.minY,
            width: CGFloat(size),
            height: CGFloat(size)
        )
        return ciContext.createCGImage(output, from: target)
    }

    /// M1-9：同一份透视校正结果直接渲染进 CVPixelBuffer。
    private static func renderCell(
        _ content: CIImage,
        grid: BoardGrid,
        row: Int,
        col: Int,
        size: Int,
        inset: CGFloat,
        width: CGFloat,
        height: CGFloat,
        into buffer: CVPixelBuffer
    ) -> Bool {
        guard let output = rectifiedImage(
            content,
            grid: grid,
            row: row,
            col: col,
            size: size,
            inset: inset,
            width: width,
            height: height
        ) else { return false }
        return PixelBufferRenderer.render(output, to: buffer, context: ciContext)
    }

    /// 与预览/OCR 相同的裁剪方式，并把 extent 平移到 (0,0)。
    /// 供自动采样做缩略图指纹复用，避免重复一段裁剪逻辑。
    static func contentImage(from frame: CapturedFrame) throws -> CIImage {
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

    /// 取一格的透视校正结果（浮点 extent，尺寸为 `size`）。
    /// CGImage 与 CVPixelBuffer 两条路径共用，避免几何口径漂移。
    private static func rectifiedImage(
        _ image: CIImage,
        grid: BoardGrid,
        row: Int,
        col: Int,
        size: Int,
        inset: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> CIImage? {
        let bounds = grid.cellRect(row: row, col: col, inset: inset)
        let topLeft = pixelPoint(
            grid.point(u: bounds.u0, v: bounds.v0), width: width, height: height
        )
        let topRight = pixelPoint(
            grid.point(u: bounds.u1, v: bounds.v0), width: width, height: height
        )
        let bottomLeft = pixelPoint(
            grid.point(u: bounds.u0, v: bounds.v1), width: width, height: height
        )
        let bottomRight = pixelPoint(
            grid.point(u: bounds.u1, v: bounds.v1), width: width, height: height
        )
        return rectify(
            image,
            topLeft: topLeft,
            topRight: topRight,
            bottomLeft: bottomLeft,
            bottomRight: bottomRight,
            size: size
        )
    }

    /// 用透视校正把任意四边形格子拉成固定尺寸的正方形。
    private static func rectify(
        _ image: CIImage,
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomLeft: CGPoint,
        bottomRight: CGPoint,
        size: Int
    ) -> CIImage? {
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

        guard let output = filter.outputImage else { return nil }
        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        return output.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(size) / extent.width,
                y: CGFloat(size) / extent.height
            )
        )
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

    /// 同一毫秒内手动/自动各存一份时也不覆盖：冲突就加序号后缀。
    private static func uniqueDirectory(in rootURL: URL) -> URL {
        let base = "snapshot-\(folderTimestamp(Date()))"
        var candidate = rootURL.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(base)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }
}
