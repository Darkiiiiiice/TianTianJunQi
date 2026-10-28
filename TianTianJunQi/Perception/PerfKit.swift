import Darwin
import Foundation
import Observation
import QuartzCore

/// M1-9：性能采样与验收。
///
/// 只做“记录 + 统计 + 报告”，不参与感知/动作逻辑。
/// 各阶段由对应服务在真实执行路径上打点；离线回放基准复用同一套统计口径。
nonisolated enum PerfClock {
    /// 主机时钟（秒）。与 `CapturedFrame.capturedAt`、SCStream PTS 同一时基。
    @inline(__always)
    static func now() -> Double { CACurrentMediaTime() }

    /// 从 `start` 到现在的毫秒数。
    @inline(__always)
    static func milliseconds(since start: Double) -> Double {
        (now() - start) * 1000
    }
}

/// 延迟阶段。`allCases` 的顺序就是报告/UI 的展示顺序。
enum PerfStage: String, CaseIterable, Codable, Sendable {
    case screenOCR = "screen.ocr"
    case screenClassify = "screen.classify"
    case screenTotal = "screen.total"
    case boardClassify = "board.classify"
    case boardState = "board.state"
    case tapDecision = "tap.decision"
    case tapClick = "tap.click"
    case endToEnd = "endToEnd"

    var label: String {
        switch self {
        case .screenOCR: "屏幕 OCR"
        case .screenClassify: "屏幕分类"
        case .screenTotal: "屏幕识别合计"
        case .boardClassify: "棋子分类"
        case .boardState: "状态构建"
        case .tapDecision: "动作决策"
        case .tapClick: "点击注入"
        case .endToEnd: "端到端"
        }
    }

    /// 参考预算（毫秒）。只有 `.endToEnd` 是验收硬门槛，其余用于定位瓶颈。
    var referenceBudgetMilliseconds: Double? {
        switch self {
        case .screenOCR: 120
        case .screenClassify: 15
        case .screenTotal: 140
        case .boardClassify: 100
        case .boardState: 15
        case .tapDecision: 5
        case .tapClick: 60
        case .endToEnd: PerformanceBudget.endToEndMilliseconds
        }
    }

    var isAcceptanceGate: Bool { self == .endToEnd }
}

enum PerformanceBudget {
    /// 设计文档 §8.7：感知 → 动作端到端 < 200ms。
    static let endToEndMilliseconds: Double = 200
}

struct LatencyStats: Codable, Equatable, Sendable {
    let count: Int
    let minMilliseconds: Double
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double
    let meanMilliseconds: Double

    var shortText: String {
        String(format: "p50 %.0f / p95 %.0f / max %.0fms", p50Milliseconds, p95Milliseconds, maxMilliseconds)
    }
}

/// 固定容量的环形采样器（纯值类型，便于单测/回放）。
struct LatencyRecorder: Equatable, Sendable {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    mutating func record(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        values.append(milliseconds)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    mutating func reset() {
        values.removeAll(keepingCapacity: true)
    }

    var stats: LatencyStats? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let count = sorted.count
        let sum = sorted.reduce(0, +)
        return LatencyStats(
            count: count,
            minMilliseconds: sorted[0],
            p50Milliseconds: Self.percentile(sorted, 0.50),
            p95Milliseconds: Self.percentile(sorted, 0.95),
            maxMilliseconds: sorted[count - 1],
            meanMilliseconds: sum / Double(count)
        )
    }

    /// 最近秩百分位：p95 不会因为插值把单次尖峰抹平。
    static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(max(percentile, 0), 1)
        let rank = Int((clamped * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}

struct PerfStageResult: Codable, Equatable, Sendable {
    let stage: PerfStage
    let stats: LatencyStats
    let referenceBudgetMilliseconds: Double?

    var isWithinReferenceBudget: Bool? {
        guard let referenceBudgetMilliseconds else { return nil }
        return stats.p95Milliseconds <= referenceBudgetMilliseconds
    }
}

struct PerfReport: Codable, Equatable, Sendable {
    let version: Int
    let createdAt: Date
    let source: String
    let sampleCount: Int
    let endToEndBudgetMilliseconds: Double
    let passed: Bool
    let stages: [PerfStageResult]
    let environment: [String: String]
    let note: String?
    let screenAccuracy: Double?
    /// M1-9：回放基准的棋子状态/明子识别准确率；实时报告为 nil。
    let boardStateAccuracy: Double?
    let boardPieceAccuracy: Double?

    static func make(
        source: String,
        recorders: [PerfStage: LatencyRecorder],
        environment: [String: String] = PerfEnvironment.current(),
        note: String? = nil,
        screenAccuracy: Double? = nil,
        boardStateAccuracy: Double? = nil,
        boardPieceAccuracy: Double? = nil,
        createdAt: Date = Date()
    ) -> PerfReport {
        let stages = PerfStage.allCases.compactMap { stage -> PerfStageResult? in
            guard let stats = recorders[stage]?.stats else { return nil }
            return PerfStageResult(
                stage: stage,
                stats: stats,
                referenceBudgetMilliseconds: stage.referenceBudgetMilliseconds
            )
        }
        let endToEnd = recorders[.endToEnd]?.stats
        return PerfReport(
            version: 1,
            createdAt: createdAt,
            source: source,
            sampleCount: endToEnd?.count ?? recorders.values.map(\.values.count).max() ?? 0,
            endToEndBudgetMilliseconds: PerformanceBudget.endToEndMilliseconds,
            passed: endToEnd.map {
                $0.p95Milliseconds < PerformanceBudget.endToEndMilliseconds
            } ?? false,
            stages: stages,
            environment: environment,
            note: note,
            screenAccuracy: screenAccuracy,
            boardStateAccuracy: boardStateAccuracy,
            boardPieceAccuracy: boardPieceAccuracy
        )
    }

    func stage(_ stage: PerfStage) -> PerfStageResult? {
        stages.first { $0.stage == stage }
    }

    var summaryText: String {
        guard let end = stage(.endToEnd)?.stats else {
            return "无端到端样本"
        }
        return String(
            format: "端到端 p50 %.0f / p95 %.0fms · %@",
            end.p50Milliseconds,
            end.p95Milliseconds,
            passed ? "达标" : "超预算"
        )
    }
}

enum PerfEnvironment {
    /// 报告附带的环境信息：机器/系统/负载，避免把系统抢占误判成代码退化。
    static func current(extra: [String: String] = [:]) -> [String: String] {
        var info = extra
        let process = ProcessInfo.processInfo
        info["macOS"] = process.operatingSystemVersionString
        if let cpu = sysctlString("machdep.cpu.brand_string") {
            info["cpu"] = cpu
        }
        if let model = sysctlString("hw.model") {
            info["model"] = model
        }
        info["physicalMemoryGB"] = String(
            format: "%.0f", Double(process.physicalMemory) / 1_073_741_824
        )

        var loads = [Double](repeating: 0, count: 3)
        let count = loads.withUnsafeMutableBufferPointer {
            getloadavg($0.baseAddress, 3)
        }
        if count == 3 {
            info["loadAverage"] = loads
                .map { String(format: "%.2f", $0) }
                .joined(separator: ",")
        }
        return info
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}

/// 应用内实时性能面板（M1-9）。
@MainActor
@Observable
final class PerformanceMonitor {
    private(set) var recorders: [PerfStage: LatencyRecorder] = [:]
    private(set) var lastReportURL: URL?
    private(set) var lastReportAt: Date?

    private static let reportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    func record(_ stage: PerfStage, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        var recorder = recorders[stage] ?? LatencyRecorder()
        recorder.record(milliseconds)
        recorders[stage] = recorder
    }

    func reset() {
        recorders.removeAll()
        lastReportURL = nil
        lastReportAt = nil
    }

    var endToEndStats: LatencyStats? {
        recorders[.endToEnd]?.stats
    }

    var summaryText: String {
        if let end = endToEndStats {
            let ocr = recorders[.screenOCR]?.stats
            let board = recorders[.boardClassify]?.stats
            let verdict = end.p95Milliseconds < PerformanceBudget.endToEndMilliseconds
                ? "达标" : "超预算"
            var text = String(format: "端到端 p95 %.0fms · %@", end.p95Milliseconds, verdict)
            if let ocr {
                text += String(format: " · OCR %.0fms", ocr.p95Milliseconds)
            }
            if let board {
                text += String(format: " · 棋盘 %.0fms", board.p95Milliseconds)
            }
            return text
        }
        if let screen = recorders[.screenTotal]?.stats {
            return String(
                format: "屏幕识别 p50 %.0f / p95 %.0fms · 等待动作样本",
                screen.p50Milliseconds,
                screen.p95Milliseconds
            )
        }
        return "等待感知样本…"
    }

    func makeReport(source: String = "live", note: String? = nil) -> PerfReport {
        PerfReport.make(
            source: source,
            recorders: recorders,
            note: note
        )
    }

    /// 把当前窗口的统计写入 `perception/performance/perf-live-时间戳.json`。
    @discardableResult
    func exportReport(source: String = "live", note: String? = nil) -> URL? {
        let report = makeReport(source: source, note: note)
        let storage = StorageKit()
        do {
            try FileManager.default.createDirectory(
                at: storage.performanceURL,
                withIntermediateDirectories: true
            )
            let name = "perf-\(source)-\(Self.reportDateFormatter.string(from: Date())).json"
            let url = storage.performanceURL.appendingPathComponent(name)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: url, options: .atomic)
            lastReportURL = url
            lastReportAt = Date()
            return url
        } catch {
            return nil
        }
    }
}
