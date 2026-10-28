import CoreGraphics
import CoreVideo
import Foundation
import Observation

/// 屏幕状态识别：Core ML 七分类器为主，Vision OCR 做兜底与锚点定位（M1-7）。
///
/// 实际的 OCR/分类/融合在 `ScreenAnalyzer` 里，本类型只负责 MainActor 状态、
/// 节流和性能打点；离线回放基准复用同一套分析内核。
@MainActor
@Observable
final class ScreenStateService {
    static let mainKeyword = ScreenAnalyzer.mainKeyword
    static let modeLobbyKeyword = ScreenAnalyzer.modeLobbyKeyword

    private(set) var state: ScreenState = .unknown
    private(set) var stateSource: ScreenStateFusion.Source = .none
    /// 开局横幅（翻旗定阵营 / 对局正式开始）是否还在；横幅压在棋盘中间，会挡住宿位。
    private(set) var showsBoardBanner = false
    /// "翻翻棋"入口包围盒（仅 .main 状态有意义）。
    private(set) var entryRect: CGRect?
    private(set) var lastOCRAt: Date?
    /// 最近一次 OCR 文本（供日志页与校准）。
    private(set) var lastOCRText: [String] = []
    private(set) var hits: [OCRText] = []
    /// M1-8：最近一次弹窗识别结果（状态不是 popup 时为 nil）。
    private(set) var popupResolution: PopupResolution?

    /// M1-7：屏幕分类器状态与最近一次推理指标。
    private(set) var classifierStatus = "未加载"
    private(set) var isClassifierReady = false
    private(set) var classifierConfidence: Double?
    private(set) var classifierMilliseconds: Double?

    /// M1-9：OCR 单遍/总耗时与本次跑了几遍（1 或 2）。
    private(set) var lastOCRMilliseconds: Double?
    private(set) var lastAnalysisMilliseconds: Double?
    private(set) var lastOCREPasses = 0

    /// M1-9：实时性能采样（由 MainView 注入）。
    var performance: PerformanceMonitor?

    private var analyzing = false
    @ObservationIgnored private var classifier: ScreenClassifier?
    @ObservationIgnored private var classifierError: String?

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
            ScreenAnalyzer.analyze(
                pixelBuffer: pixelBuffer,
                contentRect: contentRect,
                classifier: predictor
            )
        }.value

        hits = analysis.hits
        lastOCRText = analysis.hits.map(\.text)
        classifierMilliseconds = analysis.classifierMilliseconds
        classifierConfidence = analysis.prediction?.confidence
        lastOCRMilliseconds = analysis.ocrMilliseconds
        lastAnalysisMilliseconds = analysis.totalMilliseconds
        lastOCREPasses = analysis.ocrPasses

        state = analysis.state
        stateSource = analysis.source
        popupResolution = analysis.popupResolution
        showsBoardBanner = analysis.showsBoardBanner
        entryRect = analysis.entryRect

        performance?.record(.screenOCR, milliseconds: analysis.ocrMilliseconds)
        if let milliseconds = analysis.classifierMilliseconds {
            performance?.record(.screenClassify, milliseconds: milliseconds)
        }
        performance?.record(.screenTotal, milliseconds: analysis.totalMilliseconds)
    }

    /// 在最近一次 OCR 结果里找关键字包围盒（取面积最大者，用于点击中心）。
    func locate(_ keyword: String) -> CGRect? {
        ScreenAnalyzer.locate(keyword, in: hits)
    }
}
