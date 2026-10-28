import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 一份屏幕样本的 meta.json。目录名沿用 `screen-YYYYMMDD-HHMMSS-mmm`，
/// 与棋盘样本同级的 `perception/samples` 区分开。
struct ScreenSampleManifest: Codable, Sendable {
    var version: Int = 1
    let createdAt: Date
    /// ScreenState.rawValue（main/modeLobby/...）。
    let label: String
    /// manual / script / auto。
    let source: String
    let windowSize: CGSize?
    let contentPixelSize: CGSize
    /// 采集时的 OCR/模型提示，便于之后复核标签。
    let note: String?
}

enum ScreenSampleError: LocalizedError {
    case invalidFrame
    case pngWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFrame: "抓帧内容区为空，无法采集屏幕样本"
        case .pngWriteFailed(let path): "写入屏幕样本失败：\(path)"
        }
    }
}

/// M1-7 屏幕分类器数据采集：保存窗口内容区整帧 + 人工标签。
///
/// 采集入口在概览页「屏幕样本」行；训练端用 `wgai screen-dataset` 消费。
struct ScreenSampleExporter {
    var rootURL: URL = StorageKit().screenSamplesURL

    nonisolated private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    @discardableResult
    func export(
        frame: CapturedFrame,
        label: ScreenState,
        windowSize: CGSize?,
        source: String = "manual",
        note: String? = nil
    ) throws -> URL {
        let content = try BoardSnapshotExporter.contentImage(from: frame)
        guard content.extent.width > 8, content.extent.height > 8 else {
            throw ScreenSampleError.invalidFrame
        }
        guard let image = Self.ciContext.createCGImage(content, from: content.extent) else {
            throw ScreenSampleError.invalidFrame
        }

        let directory = Self.uniqueDirectory(in: rootURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let frameURL = directory.appendingPathComponent("frame.png")
        guard let destination = CGImageDestinationCreateWithURL(
            frameURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ScreenSampleError.pngWriteFailed(frameURL.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenSampleError.pngWriteFailed(frameURL.path)
        }

        let manifest = ScreenSampleManifest(
            createdAt: Date(),
            label: label.rawValue,
            source: source,
            windowSize: windowSize,
            contentPixelSize: CGSize(width: image.width, height: image.height),
            note: note
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("meta.json"),
            options: .atomic
        )
        return directory
    }

    /// 按类别统计已采集样本数；概览页显示用。
    static func counts(rootURL: URL = StorageKit().screenSamplesURL) -> [ScreenState: Int] {
        var counts: [ScreenState: Int] = [:]
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return counts
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for directory in directories where directory.lastPathComponent.hasPrefix("screen-") {
            guard let data = try? Data(
                contentsOf: directory.appendingPathComponent("meta.json")
            ),
                  let manifest = try? decoder.decode(ScreenSampleManifest.self, from: data),
                  let label = ScreenState(classifierLabel: manifest.label)
            else { continue }
            counts[label, default: 0] += 1
        }
        return counts
    }

    private static func folderTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static func uniqueDirectory(in rootURL: URL) -> URL {
        let base = "screen-\(folderTimestamp(Date()))"
        var candidate = rootURL.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(base)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }
}
