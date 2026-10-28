import CoreImage
import CoreVideo
import Observation
import Vision

/// 屏幕状态识别：Core ML 七分类器为主，Vision OCR 做兜底与锚点定位（M1-7）。
///
/// OCR 仍每帧保留：它提供“翻翻棋”入口包围盒、开局横幅判定，
/// 这些是分类器输出不了的局部信息。分类器只负责界面状态。
@MainActor
@Observable
final class ScreenStateService {
    static let mainKeyword = "翻棋"
    static let modeLobbyKeyword = "新手场"

    private static let mainKeywords = [
        "翻棋", "四国军棋", "排位赛", "每日签到", "免费抽奖",
        "大转盘", "任务", "布局", "商城",
    ]
    private static let modeLobbyKeywords = ["最低携带", "无限制", "新手场", "普通场", "大师场"]
    private static let matchingKeywords = ["正在匹配小伙伴", "匹配小伙伴", "每局扣除门票"]
    private static let boardKeywords = [
        "翻旗定阵营", "连续两次翻到同色", "最近翻旗",
        "对局正式开始", "对方走棋", "我方走棋", "轮到你走", "轮到对方",
    ]
    private static let boardBannerKeywords = [
        "翻旗定阵营", "连续两次翻到同色", "对局正式开始", "先翻棋",
    ]
    private static let resultKeywords = [
        "再来一局", "切换对手", "战败", "战胜", "投降", "获胜", "胜利", "失败",
    ]
    private static let popupKeywords = [
        "游戏规则", "玩法规则", "布局规则", "吃子规则", "行走路线",
        // 退出确认框：模型容易把压暗的牌局 + 弹窗误判成 matching，
        // 这两句是它独有的文案，命中即暂停。
        "判负", "扣除", "确定要退出",
    ]
    private static let boardStepPattern = #"第\s*\d+\s*步"#

    /// 识别结果来源，概览页/日志用。
    typealias StateSource = ScreenStateFusion.Source

    private(set) var state: ScreenState = .unknown
    private(set) var stateSource: StateSource = .none
    /// 开局横幅（翻旗定阵营 / 对局正式开始）是否还在；横幅压在棋盘中间，会挡住宿位。
    private(set) var showsBoardBanner = false
    /// "翻翻棋"入口包围盒（仅 .main 状态有意义）。
    private(set) var entryRect: CGRect?
    private(set) var lastOCRAt: Date?
    /// 最近一次 OCR 文本（供日志页与校准）。
    private(set) var lastOCRText: [String] = []
    private(set) var hits: [OCRText] = []

    /// M1-7：屏幕分类器状态与最近一次推理指标。
    private(set) var classifierStatus = "未加载"
    private(set) var isClassifierReady = false
    private(set) var classifierConfidence: Double?
    private(set) var classifierMilliseconds: Double?

    private var analyzing = false
    @ObservationIgnored private var classifier: ScreenClassifier?
    @ObservationIgnored private var classifierError: String?

    nonisolated private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 启动时预编译/加载并预热 Core ML 屏幕分类器；失败不阻塞 OCR 兜底。
    func prepare() async {
        guard !isClassifierReady, classifierError == nil else { return }
        classifierStatus = "加载中…"
        do {
            let predictor = try ScreenClassifier()
            let milliseconds = try await Task.detached(priority: .utility) {
                try predictor.warmUp()
            }.value
            classifier = predictor
            isClassifierReady = true
            classifierError = nil
            classifierStatus = String(format: "已预热 %.1fms", milliseconds)
        } catch {
            classifier = nil
            isClassifierReady = false
            classifierError = error.localizedDescription
            classifierStatus = "OCR 兜底（\(error.localizedDescription)）"
        }
    }

    /// 对一帧做分类 + OCR；minInterval 传 0 强制刷新。
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
        let contentRect = frame.contentRect
        let predictor = classifier
        let analysis = await Task.detached(priority: .userInitiated) {
            let hits = Self.recognize(pixelBuffer, contentRect: contentRect)
            var prediction: ScreenPrediction?
            var milliseconds: Double?
            if let predictor {
                let started = Date()
                prediction = try? predictor.predict(
                    pixelBuffer: pixelBuffer,
                    contentRect: contentRect
                )
                milliseconds = Date().timeIntervalSince(started) * 1000
            }
            return ScreenAnalysis(hits: hits, prediction: prediction, milliseconds: milliseconds)
        }.value

        hits = analysis.hits
        lastOCRText = analysis.hits.map(\.text)
        classifierMilliseconds = analysis.milliseconds
        classifierConfidence = analysis.prediction?.confidence

        let ocrState = Self.classify(analysis.hits)
        let resolved = ScreenStateFusion.resolve(
            modelLabel: analysis.prediction?.label,
            confidence: analysis.prediction?.confidence ?? 0,
            ocrState: ocrState,
            minConfidence: ScreenClassifier.defaultMinConfidence
        )
        state = resolved.state
        stateSource = resolved.source

        showsBoardBanner = Self.containsAny(
            Self.boardBannerKeywords,
            in: analysis.hits.map(\.text).joined(separator: " ")
        )
        entryRect = Self.locate(Self.mainKeyword, in: analysis.hits)
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

    // MARK: - 状态融合

    private struct ScreenAnalysis: @unchecked Sendable {
        let hits: [OCRText]
        let prediction: ScreenPrediction?
        let milliseconds: Double?
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
        if containsAny(modeLobbyKeywords, in: text) { return .modeLobby }
        if containsAny(mainKeywords, in: text) { return .main }
        return .unknown
    }

    private static func containsAny(_ keywords: [String], in text: String) -> Bool {
        keywords.contains { text.contains($0) }
    }

    // MARK: - Vision

    /// 两个方向各跑一遍：横排文字 + 逆时针转正后的竖排文字。
    /// 先裁到内容区（SCStream 帧是小游戏原生画布，四周有黑边），
    /// 裁完的归一化坐标才与窗口坐标一一对应。
    /// 小窗口先放大再识别：368×251 的窗口里"翻翻棋"艺术字会漏识别（P0-4 实测）。
    nonisolated private static func recognize(
        _ pixelBuffer: CVPixelBuffer,
        contentRect: CGRect
    ) -> [OCRText] {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return [] }

        let crop = CGRect(
            x: extent.minX + contentRect.minX * extent.width,
            y: extent.minY + contentRect.minY * extent.height,
            width: contentRect.width * extent.width,
            height: contentRect.height * extent.height
        )
        let cropped = contentRect == CapturedFrame.fullFrame ? image : image.cropped(to: crop)

        // 2× 放大是实测有效的阈值：368×251 窗口 2× 后能认出"翻翻棋"，
        // 1.6× 仍会识别成"翻翻旗"。
        let scale: CGFloat = cropped.extent.width < 1200 ? 2.0 : 1.0
        let prepared = scale > 1
            ? cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : cropped
        guard let base = ciContext.createCGImage(prepared, from: prepared.extent) else {
            return []
        }
        var results = perform(
            handler: VNImageRequestHandler(cgImage: base, orientation: .up),
            rotatedCCW: false
        )

        // 逆时针 90°：(x, y) → (H - y, x)，把顺时针旋转的文字转正。
        let rotate = CGAffineTransform(
            a: 0, b: 1, c: -1, d: 0, tx: prepared.extent.height, ty: 0
        )
        let rotated = prepared.transformed(by: rotate)
        guard let rotatedImage = ciContext.createCGImage(
            rotated, from: rotated.extent.integral
        ) else { return results }
        results += perform(
            handler: VNImageRequestHandler(cgImage: rotatedImage, orientation: .up),
            rotatedCCW: true
        )
        return results
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
