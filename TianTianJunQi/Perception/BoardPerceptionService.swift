import CoreGraphics
import Foundation
import Observation

struct BoardPerceptionConfig: Equatable, Sendable {
    /// 轮询间隔（秒）。0.2s × 3 帧投票 ≈ 0.4–0.6s 稳定，兼顾翻牌动画与延迟。
    var pollInterval: TimeInterval = 0.2
    var cellSize = 128
    var inset: CGFloat = 0.04
    var minConfidence = 0.55
    /// 计时器/轮次局部 OCR 的最小间隔（秒），比棋盘推理省很多。
    var timerInterval: TimeInterval = 1.0
    var readTimers = true
    var stabilizer = BoardStabilizerConfig()
}

/// M1-4 实时棋局感知：分类器逐帧推理 → BoardStabilizer 时序平滑 → 稳定棋盘。
///
/// 只在牌局界面工作；离开牌局会重置投票历史，避免上一局状态污染新局。
/// 与 `BoardAutoSampler` 并行、互不影响（各自持有轮询循环）。
@MainActor
@Observable
final class BoardPerceptionService {
    enum Phase: Equatable, Sendable {
        case off
        case waitingForBoard
        case running
        case settling
        case failed(String)
    }

    private static let enabledKey = "perception.live.enabled"
    private static let myColorKey = "perception.live.myColor"

    private(set) var phase: Phase = .off
    private(set) var board: StabilizedBoard?
    /// M1-5：稳定棋盘 + 轮次/计时构建的 GameState（JSON 可直接落 episode）。
    private(set) var gameState: GameState?
    private(set) var stateJSON: String?
    private(set) var timers: BoardTimerReading?
    /// 最近一次「切图 + 推理 + 投票」耗时（毫秒），M1-9 延迟验收用。
    private(set) var lastInferenceMilliseconds: Double?
    private(set) var lastUpdatedAt: Date?
    /// 当前稳定棋盘所用的最新帧捕获时刻（`CapturedFrame.capturedAt`，主机时钟秒）。
    /// 动作链路用它计算「感知 → 动作」的真实端到端延迟。
    private(set) var lastFrameCapturedAt: Double?
    /// 本次会话累计推理帧数。
    private(set) var observationCount = 0

    /// 我方执色；换色后重算棋盘归属。
    var myColor: PieceColor {
        didSet {
            guard myColor != oldValue else { return }
            UserDefaults.standard.set(myColor.rawValue, forKey: Self.myColorKey)
            stateBuilder.reset()
            stateBuilder.myColor = myColor
            gameState = nil
            stateJSON = nil
        }
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled {
                reset()
                phase = .off
            }
        }
    }

    var config = BoardPerceptionConfig()
    /// M1-9：实时延迟采样（由 MainView 注入）。
    var performance: PerformanceMonitor?

    @ObservationIgnored private var stabilizer: BoardStabilizer
    @ObservationIgnored private var classifier: BoardPieceClassifier?
    @ObservationIgnored private var classifierError: String?
    @ObservationIgnored private var stateBuilder: BoardStateBuilder
    @ObservationIgnored private var turnReader = BoardTurnReader()
    @ObservationIgnored private var lastTimerAt: Date?
    @ObservationIgnored private var inFlight = false

    init(config: BoardPerceptionConfig = BoardPerceptionConfig()) {
        self.config = config
        self.stabilizer = BoardStabilizer(config: config.stabilizer)
        let storedColor = UserDefaults.standard.string(forKey: Self.myColorKey)
            .flatMap(PieceColor.init(rawValue:))
        let color = storedColor ?? .red
        self.myColor = color
        self.stateBuilder = BoardStateBuilder(
            config: BoardStateBuilderConfig(myColor: color)
        )
        let stored = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
        self.isEnabled = stored ?? true
        self.phase = isEnabled ? .waitingForBoard : .off
    }

    var counts: (empty: Int, hidden: Int, revealed: Int, unknown: Int) {
        guard let board else { return (0, 0, 0, 0) }
        var empty = 0
        var hidden = 0
        var revealed = 0
        var unknown = 0
        for cell in board.cells {
            switch cell.state {
            case .empty: empty += 1
            case .hidden: hidden += 1
            case .revealed: revealed += 1
            case .unknown: unknown += 1
            }
        }
        return (empty, hidden, revealed, unknown)
    }

    var statusText: String {
        guard isEnabled else { return "实时棋局感知已关闭" }
        switch phase {
        case .off:
            return "实时棋局感知已关闭"
        case .waitingForBoard:
            return "实时棋局感知 · 等待进入牌局…"
        case .settling:
            return "实时棋局感知 · 棋盘变化，等待稳定…"
        case .failed(let message):
            return "实时棋局感知失败：\(message)"
        case .running:
            let counts = counts
            let latency = lastInferenceMilliseconds.map { " · \(Int($0))ms" } ?? ""
            return "实时棋局感知 · 空 \(counts.empty)"
                + " / 暗 \(counts.hidden)"
                + " / 明 \(counts.revealed)"
                + " / 未知 \(counts.unknown)"
                + latency
        }
    }

    /// 概览页第二行：轮次、倒计时、可走格数（M1-5）。
    var detailText: String {
        guard let gameState else { return "尚无 GameState" }
        let turn = gameState.turn == .red ? "红方" : "黑方"
        let timer = timers?.me.map { String(format: "%.0fs", $0) }
            ?? timers?.opponent.map { String(format: "对手 %.0fs", $0) }
            ?? "计时未知"
        return "轮次 \(turn) · \(timer) · 可走 \(gameState.legalActions.count) 格"
    }

    /// 常驻循环；由 MainView 的 `.task` 持有，视图销毁时自动取消。
    func run(
        capture: CaptureService,
        calibration: CalibrationStore,
        screenState: ScreenStateService,
        store: AppStateStore,
        rows: Int,
        cols: Int
    ) async {
        while !Task.isCancelled {
            let interval = max(0.05, config.pollInterval)
            try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            guard !Task.isCancelled else { return }

            guard isEnabled else {
                phase = .off
                reset()
                continue
            }
            guard !inFlight else { continue }

            switch screenState.state {
            case .board:
                break
            case .unknown:
                // OCR 偶尔漏识别：保持当前会话，避免把同一局切成新局。
                continue
            default:
                if board != nil || observationCount > 0 {
                    reset()
                }
                phase = .waitingForBoard
                continue
            }
            // 开局横幅（翻旗定阵营 / 对局正式开始）压着棋盘，等它消失再判。
            guard !screenState.showsBoardBanner else {
                phase = .waitingForBoard
                continue
            }

            guard let calibrationValue = calibration.calibration,
                  let grid = calibrationValue.boardGrid(rows: rows, cols: cols),
                  let frame = capture.latestFrame
            else {
                phase = .waitingForBoard
                continue
            }

            if classifier == nil, classifierError == nil {
                do {
                    classifier = try BoardPieceClassifier(
                        config: BoardPieceClassifier.Config(
                            cellSize: config.cellSize,
                            inset: config.inset,
                            minConfidence: config.minConfidence
                        )
                    )
                } catch {
                    classifierError = error.localizedDescription
                    phase = .failed(error.localizedDescription)
                    store.note("棋子分类器加载失败：\(error.localizedDescription)")
                    continue
                }
            }
            guard let classifier else { continue }

            inFlight = true
            let classifyStarted = PerfClock.now()
            let observation = await Task.detached(priority: .userInitiated) {
                try? classifier.classify(frame: frame, grid: grid)
            }.value
            let classifyMilliseconds = PerfClock.milliseconds(since: classifyStarted)
            performance?.record(.boardClassify, milliseconds: classifyMilliseconds)

            let stabilizeStarted = PerfClock.now()
            let output = observation.flatMap {
                stabilizer.update($0, at: Date().timeIntervalSinceReferenceDate)
            }
            let stabilizeMilliseconds = PerfClock.milliseconds(since: stabilizeStarted)
            inFlight = false

            guard let output else {
                phase = .failed("分类或投票失败")
                continue
            }

            board = output
            lastInferenceMilliseconds = classifyMilliseconds + stabilizeMilliseconds
            lastFrameCapturedAt = frame.capturedAt
            lastUpdatedAt = Date()
            observationCount += 1
            phase = output.isSettling ? .settling : .running

            // M1-5：轮次/计时器局部 OCR（1s 一次即可），然后构建 GameState。
            let now = Date()
            if config.readTimers,
               now.timeIntervalSince(lastTimerAt ?? .distantPast) >= config.timerInterval {
                let hits = screenState.hits
                let reader = turnReader
                timers = await Task.detached(priority: .utility) {
                    reader.read(frame: frame, hits: hits)
                }.value
                lastTimerAt = now
            }

            let buildStarted = PerfClock.now()
            let state = stateBuilder.build(board: output, timers: timers)
            gameState = state
            stateJSON = state.jsonString()
            performance?.record(
                .boardState,
                milliseconds: PerfClock.milliseconds(since: buildStarted) + stabilizeMilliseconds
            )
        }
    }

    private func reset() {
        stabilizer.reset()
        stateBuilder.reset()
        board = nil
        gameState = nil
        stateJSON = nil
        timers = nil
        lastTimerAt = nil
        lastUpdatedAt = nil
        lastFrameCapturedAt = nil
        observationCount = 0
    }
}
