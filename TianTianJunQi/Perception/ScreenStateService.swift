import CoreVideo
import Observation
import Vision

/// 屏幕状态（M0-6 v0：规则 + Vision OCR；Create ML 分类器在 M1-7 接入）。
enum ScreenState: String, Sendable {
    case unknown
    /// 游戏主菜单（OCR 命中"翻翻棋"入口）。
    case main
    /// 牌局（关键词待 P0-3/M1 实测后补充）。
    case board
}

/// 屏幕状态识别服务：对最新帧做节流 OCR，输出状态与入口包围盒。
/// OCR 单次 10-30ms，由低频定时器（约 2s）驱动，不随抓帧频率跑。
@MainActor
@Observable
final class ScreenStateService {
    /// 入口 OCR 关键字（P0-2 实测：按钮艺术字"翻翻翻棋"，用"翻棋"子串更稳）。
    private static let entryKeywords = ["翻棋"]

    private(set) var state: ScreenState = .unknown
    /// "翻翻棋"入口包围盒：归一化 0..1、左上原点，相对整窗（含标题栏）。
    private(set) var entryRect: CGRect?
    private(set) var lastOCRAt: Date?
    /// 最近一次 OCR 文本（供日志页与 P0-2 校准）。
    private(set) var lastOCRText: [String] = []

    private var analyzing = false

    /// 对一帧做 OCR 分析；minInterval 传 0 强制刷新。
    func analyzeIfNeeded(frame: CapturedFrame, minInterval: TimeInterval = 1.0) async {
        guard !analyzing else { return }
        if let last = lastOCRAt, Date().timeIntervalSince(last) < minInterval { return }
        analyzing = true
        defer { analyzing = false }
        lastOCRAt = Date()

        let pixelBuffer = frame.pixelBuffer
        let observations = await Task.detached(priority: .userInitiated) {
            Self.recognizeText(in: pixelBuffer)
        }.value

        let texts = observations.map { Self.topText($0) }
        lastOCRText = Array(texts.prefix(40))

        // 入口定位：命中关键字的候选里取面积最大者
        var best: VNRecognizedTextObservation?
        var bestArea: CGFloat = 0
        for observation in observations {
            let text = Self.topText(observation)
            let hit = Self.entryKeywords.contains { text.contains($0) }
            guard hit else { continue }
            let box = observation.boundingBox
            let area = box.width * box.height
            if area > bestArea {
                best = observation
                bestArea = area
            }
        }
        if let best {
            let box = best.boundingBox // VN 归一化、左下原点
            entryRect = CGRect(
                x: box.minX,
                y: 1 - box.maxY, // 转左上原点
                width: box.width,
                height: box.height
            )
            state = .main
        } else {
            entryRect = nil
            state = .unknown
        }
    }

    private static func topText(_ observation: VNRecognizedTextObservation) -> String {
        observation.topCandidates(1).first?.string ?? ""
    }

    /// 同步 OCR（在后台线程调用）；Vision 文本识别，简体中文，不做语言纠正。
    nonisolated private static func recognizeText(
        in pixelBuffer: CVPixelBuffer
    ) -> [VNRecognizedTextObservation] {
        var results: [VNRecognizedTextObservation] = []
        let request = VNRecognizeTextRequest { request, _ in
            results = (request.results as? [VNRecognizedTextObservation]) ?? []
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do { try handler.perform([request]) } catch { return [] }
        return results
    }
}
