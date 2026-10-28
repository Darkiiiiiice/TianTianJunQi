import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 一份弹窗现场样本的 meta.json（M1-8）。
///
/// 未知弹窗必须保留现场：整帧 + OCR 行 + 命中/暂停原因，方便之后补模板。
struct PopupSampleManifest: Codable, Sendable {
    var version: Int = 1
    let createdAt: Date
    /// unknown / blocked / stalled。
    let kind: String
    /// 已知模板 rawValue；未知弹窗为 nil。
    let template: String?
    let screenState: String
    let windowSize: CGSize?
    let contentPixelSize: CGSize
    let note: String?
    let ocr: [PopupOCRLine]
}

struct PopupOCRLine: Codable, Sendable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Float

    nonisolated init(_ hit: OCRText) {
        text = hit.text
        x = hit.rect.minX
        y = hit.rect.minY
        width = hit.rect.width
        height = hit.rect.height
        confidence = hit.confidence
    }
}

enum PopupSampleError: LocalizedError {
    case invalidFrame
    case pngWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFrame: "抓帧内容区为空，无法保存弹窗截图"
        case .pngWriteFailed(let path): "写入弹窗截图失败：\(path)"
        }
    }
}

/// 未知/无法处理弹窗的现场导出器。
///
/// 输出目录：`perception/popups/<kind>-YYYYMMDD-HHMMSS-mmm/`
/// - `frame.png`：窗口内容区整帧
/// - `meta.json`：OCR 行、模板、状态、暂停原因
/// - `ocr.txt`：便于直接查看的 OCR 文本
struct PopupSampleExporter {
    var rootURL: URL = StorageKit().popupsURL

    nonisolated private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    @discardableResult
    func export(
        frame: CapturedFrame,
        kind: String,
        template: PopupKind?,
        screenState: ScreenState,
        windowSize: CGSize?,
        note: String?,
        hits: [OCRText]
    ) throws -> URL {
        let content = try BoardSnapshotExporter.contentImage(from: frame)
        guard content.extent.width > 8, content.extent.height > 8 else {
            throw PopupSampleError.invalidFrame
        }
        guard let image = Self.ciContext.createCGImage(content, from: content.extent) else {
            throw PopupSampleError.invalidFrame
        }

        let directory = Self.uniqueDirectory(kind: kind, in: rootURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let frameURL = directory.appendingPathComponent("frame.png")
        guard let destination = CGImageDestinationCreateWithURL(
            frameURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw PopupSampleError.pngWriteFailed(frameURL.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PopupSampleError.pngWriteFailed(frameURL.path)
        }

        let manifest = PopupSampleManifest(
            createdAt: Date(),
            kind: kind,
            template: template?.rawValue,
            screenState: screenState.rawValue,
            windowSize: windowSize,
            contentPixelSize: CGSize(width: image.width, height: image.height),
            note: note,
            ocr: hits.map(PopupOCRLine.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("meta.json"),
            options: .atomic
        )

        let ocrText = hits.map {
            String(
                format: "%.3f %.3f %.3f %.3f  %@",
                $0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height, $0.text
            )
        }.joined(separator: "\n")
        try (ocrText + (ocrText.isEmpty ? "" : "\n")).write(
            to: directory.appendingPathComponent("ocr.txt"),
            atomically: true,
            encoding: .utf8
        )

        return directory
    }

    private static func folderTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static func uniqueDirectory(kind: String, in rootURL: URL) -> URL {
        let safeKind = kind.isEmpty ? "unknown" : kind
        let base = "\(safeKind)-\(folderTimestamp(Date()))"
        var candidate = rootURL.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(base)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }
}
