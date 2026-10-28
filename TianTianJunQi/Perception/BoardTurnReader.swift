import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// 轮次证据：相对我方，而不是红/黑。颜色映射交给 BoardStateBuilder（依赖 myColor）。
enum TurnSignal: String, Equatable, Sendable {
    case me
    case opponent
    case unknown
}

struct BoardTimerReading: Equatable, Sendable {
    var me: Double?
    var opponent: Double?
    var turn: TurnSignal

    static let unknown = BoardTimerReading(me: nil, opponent: nil, turn: .unknown)

    var timers: GameTimers {
        GameTimers(me: me, opponent: opponent)
    }
}

struct BoardTurnReaderConfig: Equatable, Sendable {
    /// 我方倒计时 ROI（归一化，左上原点，相对抓帧内容区）。
    /// 2026-10-28 两帧实测：倒计时在右下角 (0.903, 0.839, 0.041, 0.085)，值 19。
    var myTimerROI = CGRect(x: 0.890, y: 0.815, width: 0.075, height: 0.130)
    /// 对方倒计时 ROI：按头像位置镜像到左下（当前样本都是我方回合，尚未实测）。
    var opponentTimerROI = CGRect(x: 0.030, y: 0.815, width: 0.090, height: 0.130)
    /// 小字放大倍数；55px 宽的倒计时需要放大才能稳定识别。
    var scale: CGFloat = 3
    /// 倒计时上限（秒），超出视为 OCR 误读。
    var maxTimerSeconds: Double = 300
}

/// M1-5：轮次与计时器的局部 ROI OCR。
///
/// 只裁两个小区域跑 Vision，不重复整帧 OCR（整帧由 ScreenStateService 负责）。
/// 轮次优先用整帧 OCR 里的文案（"我方走棋"/"轮到你走"…），其次用倒计时可见性推断：
/// 只有我方计时可见 → 我方回合；只有对方计时可见 → 对方回合。
struct BoardTurnReader {
    var config = BoardTurnReaderConfig()

    func read(frame: CapturedFrame, hits: [OCRText] = []) -> BoardTimerReading {
        var me: Double?
        var opponent: Double?

        if let image = try? BoardSnapshotExporter.contentImage(from: frame) {
            me = Self.recognizeSeconds(
                in: image,
                roi: config.myTimerROI,
                scale: config.scale,
                maxSeconds: config.maxTimerSeconds
            )
            opponent = Self.recognizeSeconds(
                in: image,
                roi: config.opponentTimerROI,
                scale: config.scale,
                maxSeconds: config.maxTimerSeconds
            )
        }

        return BoardTimerReading(
            me: me,
            opponent: opponent,
            turn: Self.turnSignal(hits: hits, me: me, opponent: opponent)
        )
    }

    static func turnSignal(
        hits: [OCRText],
        me: Double?,
        opponent: Double?
    ) -> TurnSignal {
        let text = hits.map(\.text).joined(separator: " ")
        if text.contains("我方走棋") || text.contains("轮到你走") {
            return .me
        }
        if text.contains("对方走棋") || text.contains("轮到对方") {
            return .opponent
        }
        switch (me, opponent) {
        case (.some, .none):
            return .me
        case (.none, .some):
            return .opponent
        default:
            return .unknown
        }
    }

    /// 从秒数候选文本里取第一个合法整数（"19"、`"19秒"` 都能过）。
    static func parseSeconds(from texts: [String], maxSeconds: Double = 300) -> Double? {
        for text in texts {
            guard let range = text.range(of: #"\d{1,3}"#, options: .regularExpression),
                  let value = Double(text[range]),
                  value <= maxSeconds
            else { continue }
            return value
        }
        return nil
    }

    // MARK: - Vision

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    nonisolated private static func recognizeSeconds(
        in image: CIImage,
        roi: CGRect,
        scale: CGFloat,
        maxSeconds: Double
    ) -> Double? {
        let extent = image.extent
        let crop = CGRect(
            x: extent.minX + roi.minX * extent.width,
            y: extent.minY + (1 - roi.maxY) * extent.height,
            width: roi.width * extent.width,
            height: roi.height * extent.height
        ).integral
        guard crop.width > 4, crop.height > 4 else { return nil }

        let cropped = image.cropped(to: crop)
        let prepared = scale > 1
            ? cropped.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(
                        CGAffineTransform(translationX: -crop.minX * scale,
                                          y: -crop.minY * scale)
                    )
            )
            : cropped

        guard let cgImage = ciContext.createCGImage(prepared, from: prepared.extent) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.05

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return nil }
        let texts = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return parseSeconds(from: texts, maxSeconds: maxSeconds)
    }
}
