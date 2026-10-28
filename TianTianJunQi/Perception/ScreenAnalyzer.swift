import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// 一次屏幕分析的全部结果（M1-7/M1-8/M1-9）。
///
/// 从 `ScreenStateService` 抽出来，便于离线回放基准复用同一套 OCR/分类/融合逻辑，
/// 也把耗时打点固定在一处，避免实时与回放口径漂移。
struct ScreenAnalysis: Sendable {
    let hits: [OCRText]
    let prediction: ScreenPrediction?
    let state: ScreenState
    let source: ScreenStateFusion.Source
    let popupResolution: PopupResolution?
    let showsBoardBanner: Bool
    let entryRect: CGRect?
    let ocrMilliseconds: Double
    let classifierMilliseconds: Double?
    let totalMilliseconds: Double
    /// 本次 OCR 跑了几遍（1 = 只跑横排；2 = 额外跑了逆时针 90°）。
    let ocrPasses: Int
}

/// 屏幕状态识别内核：分类器为主，Vision OCR 兜底与定位。
nonisolated enum ScreenAnalyzer {
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
        // 通用弹层文案：模型没见过的新弹窗也要先归到 popup，
        // 再由 PopupResolver 判定「已知模板」或「未知弹窗 → 暂停截图」。
        "一键领取", "领取破产金", "破产金", "金币不足", "恭喜获得", "温馨提示",
    ]
    private static let boardStepPattern = #"第\s*\d+\s*步"#

    /// 对一帧做 OCR + 七分类 + 融合 + 弹窗解析。
    static func analyze(
        pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        classifier: ScreenClassifier?
    ) -> ScreenAnalysis {
        let totalStart = PerfClock.now()

        let ocrStart = PerfClock.now()
        let recognized = recognize(pixelBuffer, contentRect: contentRect)
        let ocrMilliseconds = PerfClock.milliseconds(since: ocrStart)
        let hits = recognized.hits

        var prediction: ScreenPrediction?
        var classifierMilliseconds: Double?
        if let classifier {
            let started = PerfClock.now()
            prediction = try? classifier.predict(
                pixelBuffer: pixelBuffer,
                contentRect: contentRect
            )
            classifierMilliseconds = PerfClock.milliseconds(since: started)
        }

        let ocrState = classify(hits)
        let resolved = ScreenStateFusion.resolve(
            modelLabel: prediction?.label,
            confidence: prediction?.confidence ?? 0,
            ocrState: ocrState,
            minConfidence: ScreenClassifier.defaultMinConfidence
        )
        let text = hits.map(\.text).joined(separator: " ")
        let entryRect = locate(mainKeyword, in: hits)

        return ScreenAnalysis(
            hits: hits,
            prediction: prediction,
            state: resolved.state,
            source: resolved.source,
            popupResolution: resolved.state == .popup
                ? PopupResolver.resolve(hits: hits)
                : nil,
            showsBoardBanner: containsAny(boardBannerKeywords, in: text),
            entryRect: entryRect,
            ocrMilliseconds: ocrMilliseconds,
            classifierMilliseconds: classifierMilliseconds,
            totalMilliseconds: PerfClock.milliseconds(since: totalStart),
            ocrPasses: recognized.passes
        )
    }

    /// 在最近一次 OCR 结果里找关键字包围盒（取面积最大者，用于点击中心）。
    static func locate(_ keyword: String, in hits: [OCRText]) -> CGRect? {
        hits
            .filter { $0.text.contains(keyword) }
            .max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?
            .rect
    }

    // MARK: - 状态分类

    static func classify(_ hits: [OCRText]) -> ScreenState {
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

    private struct Recognized {
        let hits: [OCRText]
        let passes: Int
    }

    /// 两个方向各跑一遍：横排文字 + 逆时针转正后的竖排文字。
    /// 实测大多数帧横排 pass 已能拿到足够文本，只有结果过少时才补第二遍，
    /// 避免每帧都为极少数旋转画面付双倍 OCR 成本。
    private static func recognize(
        _ pixelBuffer: CVPixelBuffer,
        contentRect: CGRect
    ) -> Recognized {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            return Recognized(hits: [], passes: 0)
        }

        let crop = CGRect(
            x: extent.minX + contentRect.minX * extent.width,
            y: extent.minY + contentRect.minY * extent.height,
            width: contentRect.width * extent.width,
            height: contentRect.height * extent.height
        )
        let cropped = contentRect == CapturedFrame.fullFrame ? image : image.cropped(to: crop)
        // Vision 以图像 extent 为基准；裁剪后 extent 可能不在原点，先平移到 (0,0)，
        // 保证 OCR 归一化坐标始终相对内容区（与点击坐标同一口径）。
        let normalized = cropped.transformed(
            by: CGAffineTransform(
                translationX: -cropped.extent.minX,
                y: -cropped.extent.minY
            )
        )

        // 2× 放大是实测有效的阈值：小窗口 1× 会把“翻翻棋”识别成“翻翻旗”。
        // 内容宽度 ≥ 1200 时已经是高分辨率画布，不再放大。
        let scale: CGFloat = normalized.extent.width < 1200 ? 2.0 : 1.0
        let prepared = scale > 1
            ? normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : normalized

        var hits = perform(prepared, rotatedCCW: false)
        var passes = 1
        if needsRotatedRetry(hits) {
            // 逆时针 90°：(x, y) → (H - y, x)，把顺时针旋转的文字转正。
            let rotate = CGAffineTransform(
                a: 0, b: 1, c: -1, d: 0, tx: prepared.extent.height, ty: 0
            )
            hits += perform(prepared.transformed(by: rotate), rotatedCCW: true)
            passes = 2
        }
        return Recognized(hits: hits, passes: passes)
    }

    /// 文本太少才补旋转 pass；关键界面词命中一个就认为方向已正确。
    private static func needsRotatedRetry(_ hits: [OCRText]) -> Bool {
        let meaningful = hits.filter { $0.text.count >= 2 && $0.confidence >= 0.30 }
        if meaningful.count >= 4 { return false }
        let text = hits.map(\.text).joined(separator: " ")
        let anchors = [
            "翻棋", "翻旗", "签到", "匹配", "新手场", "普通场", "大师场",
            "再来一局", "规则", "确定要退出", "领取", "任务", "对局",
        ]
        return !anchors.contains { text.contains($0) }
    }

    private static func perform(
        _ image: CIImage,
        rotatedCCW: Bool
    ) -> [OCRText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008

        do {
            try VNImageRequestHandler(ciImage: image, orientation: .up)
                .perform([request])
        } catch {
            return []
        }
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
