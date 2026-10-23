import CoreImage
import CoreVideo
import Observation
import Vision

/// 屏幕状态（M0-8 v0：规则 + Vision OCR；Create ML 分类器在 M1-7 接入）。
enum ScreenState: String, Sendable {
    case unknown
    /// 游戏主菜单（OCR 命中"翻翻棋"入口）。
    case main
    /// 场次选择页（新手场 / 普通场 / 大师场）。
    case venue
    /// 真人匹配等待页。
    case matching
    /// 牌局。
    case board
    /// 结算页（再来一局 / 切换对手）。
    case result
    /// 规则/公告/提示弹窗（M0-8 只识别并暂停；M1-8 做模板化关闭）。
    case popup

    var label: String {
        switch self {
        case .unknown: "未识别"
        case .main: "主菜单"
        case .venue: "场次选择"
        case .matching: "匹配中"
        case .board: "牌局"
        case .result: "结算页"
        case .popup: "弹窗"
        }
    }
}

/// 一条 OCR 结果：文本 + 归一化包围盒。
struct OCRText: Sendable {
    let text: String
    /// 归一化 0..1、左上原点，相对整窗（含标题栏）。
    let rect: CGRect
    let confidence: Float
}

/// 屏幕状态识别：对最新帧做节流 OCR，输出界面状态与关键字包围盒。
/// P0-4 实测：场次卡、匹配文案、结算按钮都是顺时针旋转 90° 的文字，
/// 因此同时识别原图与逆时针旋转 90° 的画面；归一化坐标映射回原图。
@MainActor
@Observable
final class ScreenStateService {
    static let mainKeyword = "翻棋"
    static let venueKeyword = "新手场"

    private static let mainKeywords = ["翻棋"]
    private static let venueKeywords = ["最低携带", "无限制", "新手场", "普通场", "大师场"]
    private static let matchingKeywords = ["正在匹配小伙伴", "匹配小伙伴", "每局扣除门票"]
    private static let boardKeywords = ["翻旗定阵营", "连续两次翻到同色", "最近翻旗"]
    private static let resultKeywords = ["再来一局", "切换对手", "战败", "战胜", "投降"]
    private static let popupKeywords = ["游戏规则", "玩法规则", "布局规则", "吃子规则", "行走路线"]
    private static let boardStepPattern = #"第\s*\d+\s*步"#

    private(set) var state: ScreenState = .unknown
    /// "翻翻棋"入口包围盒（仅 .main 状态有意义）。
    private(set) var entryRect: CGRect?
    private(set) var lastOCRAt: Date?
    /// 最近一次 OCR 文本（供日志页与校准）。
    private(set) var lastOCRText: [String] = []
    private(set) var hits: [OCRText] = []

    private var analyzing = false

    nonisolated private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 对一帧做 OCR 分析；minInterval 传 0 强制刷新。
    func analyzeIfNeeded(frame: CapturedFrame, minInterval: TimeInterval = 1.0) async {
        // 步骤引擎需要"刷新后立刻读新状态"：等在途分析结束，而不是直接返回旧结果。
        var waited = 0
        while analyzing, waited < 20 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        guard !analyzing else { return }
        if minInterval > 0, let last = lastOCRAt, Date().timeIntervalSince(last) < minInterval {
            return
        }

        analyzing = true
        defer { analyzing = false }
        lastOCRAt = Date()

        let pixelBuffer = frame.pixelBuffer
        let result = await Task.detached(priority: .userInitiated) {
            Self.recognize(pixelBuffer)
        }.value

        hits = result
        lastOCRText = result.map(\.text)
        state = Self.classify(result)
        entryRect = Self.locate(Self.mainKeyword, in: result)
    }

    /// 在最近一次 OCR 结果里找关键字包围盒（取面积最大者，用于点击中心）。
    func locate(_ keyword: String) -> CGRect? {
        Self.locate(keyword, in: hits)
    }

    private static func locate(_ keyword: String, in hits: [OCRText]) -> CGRect? {
        hits
            .filter { $0.text.contains(keyword) }
            .max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?
            .rect
    }

    private static func classify(_ hits: [OCRText]) -> ScreenState {
        let text = hits.map(\.text).joined(separator: " ")
        if containsAny(popupKeywords, in: text) { return .popup }
        if containsAny(resultKeywords, in: text) { return .result }
        if containsAny(boardKeywords, in: text)
            || text.range(of: boardStepPattern, options: .regularExpression) != nil {
            return .board
        }
        if containsAny(matchingKeywords, in: text) { return .matching }
        if containsAny(venueKeywords, in: text) { return .venue }
        if containsAny(mainKeywords, in: text) { return .main }
        return .unknown
    }

    private static func containsAny(_ keywords: [String], in text: String) -> Bool {
        keywords.contains { text.contains($0) }
    }

    // MARK: - Vision

    /// 两个方向各跑一遍：横排文字 + 逆时针转正后的竖排文字。
    nonisolated private static func recognize(_ pixelBuffer: CVPixelBuffer) -> [OCRText] {
        var results = recognize(pixelBuffer: pixelBuffer)

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return results }

        // 逆时针 90°：(x, y) → (H - y, x)，把顺时针旋转的文字转正。
        let rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: extent.height, ty: 0)
        let rotated = image.transformed(by: rotate)
        guard let cgImage = ciContext.createCGImage(rotated, from: rotated.extent.integral) else {
            return results
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        results += perform(handler: handler, rotatedCCW: true)
        return results
    }

    nonisolated private static func recognize(pixelBuffer: CVPixelBuffer) -> [OCRText] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        return perform(handler: handler, rotatedCCW: false)
    }

    nonisolated private static func perform(
        handler: VNImageRequestHandler,
        rotatedCCW: Bool
    ) -> [OCRText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008

        do { try handler.perform([request]) } catch { return [] }
        let observations = request.results ?? []

        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox // 归一化、左下原点
            let rect: CGRect
            if rotatedCCW {
                // 旋转画面（左下原点）→ 原图左上原点。
                rect = CGRect(
                    x: box.minY,
                    y: box.minX,
                    width: box.height,
                    height: box.width
                )
            } else {
                rect = CGRect(
                    x: box.minX,
                    y: 1 - box.maxY,
                    width: box.width,
                    height: box.height
                )
            }
            return OCRText(text: candidate.string, rect: rect, confidence: candidate.confidence)
        }
    }
}
