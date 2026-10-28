import CoreGraphics
import Foundation
import Observation

struct BoardTapConfig: Equatable, Sendable {
    /// 点击后等待棋盘呈现预期结果的总时长（含稳定器 2–3 帧投票）。
    var verifyTimeout: TimeInterval = 3.0
    var pollInterval: TimeInterval = 0.1
    /// 选中棋子与点目标格之间的间隔。
    var selectDelay: TimeInterval = 0.15
    var minPieceConfidence = 0.55
}

/// M1-6 落子能力：像素坐标换算 → 注入点击 → 用稳定棋盘验证结果。
///
/// 只在“已开启点击 + 我方回合 + 稳定棋盘”时动作；每次结果分三类：
/// 拒绝（未发事件）、已验证、未验证（已发事件但棋盘没给出预期变化）。
/// 绝不把“点击已发出”当成“动作成功”。
@MainActor
@Observable
final class BoardTapService {
    enum Phase: Equatable, Sendable {
        case idle
        case tapping
        case verifying
    }

    private static let armedKey = "perception.tap.armed"

    private(set) var phase: Phase = .idle
    private(set) var lastResult: BoardTapResult?
    private(set) var lastAction: BoardTapAction?
    /// 最近一次点击的窗口归一化坐标与全局点（日志/调试用）。
    private(set) var lastWindowPoint: CGPoint?
    private(set) var lastAbsolutePoint: CGPoint?

    /// 安全开关：默认关闭，必须显式打开才会向游戏注入点击。
    var isArmed: Bool {
        didSet {
            guard isArmed != oldValue else { return }
            UserDefaults.standard.set(isArmed, forKey: Self.armedKey)
        }
    }

    var config = BoardTapConfig()
    /// M1-9：实时延迟采样（由 MainView 注入）。
    var performance: PerformanceMonitor?
    /// M2-7：录制开启时，把每次已验证的点击写进 episode。
    var recorder: EpisodeRecorder?

    init(config: BoardTapConfig = BoardTapConfig()) {
        self.config = config
        self.isArmed = UserDefaults.standard.object(forKey: Self.armedKey) as? Bool ?? false
    }

    var statusText: String {
        guard isArmed else { return "点击验证 · 未开启" }
        switch phase {
        case .idle:
            return lastResult.map { "点击验证 · \($0.text)" } ?? "点击验证 · 待命"
        case .tapping:
            return "点击验证 · 正在点击…"
        case .verifying:
            return "点击验证 · 等待棋盘变化…"
        }
    }

    /// 执行一次翻牌或移动；返回可写日志的结果。
    @discardableResult
    func perform(
        _ action: BoardTapAction,
        capture: CaptureService,
        windows: WindowMonitor,
        calibration: CalibrationStore,
        screenState: ScreenStateService,
        perception: BoardPerceptionService,
        injector: InputInjector,
        store: AppStateStore,
        automatic: Bool = false
    ) async -> BoardTapResult {
        lastAction = action
        let beforeState = perception.gameState
        let result = await run(
            action,
            capture: capture,
            windows: windows,
            calibration: calibration,
            screenState: screenState,
            perception: perception,
            injector: injector,
            store: store,
            automatic: automatic
        )
        lastResult = result
        phase = .idle
        store.note("点击验证 · \(action.label) · \(result.text)")

        if result.isConfirmed,
           let recorder,
           recorder.isRecording,
           recorder.recordMode == .panel,
           let beforeState
        {
            let afterState = perception.gameState
            do {
                switch action {
                case .flip(let cell):
                    try recorder.recordFlip(
                        cell: cell,
                        state: beforeState,
                        afterState: afterState
                    )
                case .move(let from, let to):
                    try recorder.recordMove(
                        from: from,
                        to: to,
                        state: beforeState,
                        afterState: afterState
                    )
                }
            } catch {
                store.note("episode 记录失败：\(error.localizedDescription)")
            }
        }
        return result
    }

    private func run(
        _ action: BoardTapAction,
        capture: CaptureService,
        windows: WindowMonitor,
        calibration: CalibrationStore,
        screenState: ScreenStateService,
        perception: BoardPerceptionService,
        injector: InputInjector,
        store: AppStateStore,
        automatic: Bool
    ) async -> BoardTapResult {
        let decisionStartedAt = PerfClock.now()
        guard phase == .idle else { return .refused(.busy) }
        guard isArmed else { return .refused(.disarmed) }
        guard screenState.state == .board else { return .refused(.notInBoard) }
        guard !screenState.showsBoardBanner else { return .refused(.bannerVisible) }
        guard perception.phase == .running else {
            return .refused(.perceptionNotRunning)
        }
        guard let board = perception.board, let state = perception.gameState else {
            return .refused(.noStableBoard)
        }
        guard let window = windows.effectiveCandidate else { return .refused(.noWindow) }
        guard let calibrationValue = calibration.calibration,
              let grid = calibrationValue.boardGrid(rows: board.rows, cols: board.cols)
        else { return .refused(.noCalibration) }
        guard let frame = capture.latestFrame else { return .refused(.noFrame) }

        if let refusal = BoardTapVerifier.refusal(
            for: action,
            board: board,
            turn: state.turn,
            myColor: perception.myColor,
            legalActions: state.legalActions,
            phase: state.phase,
            minPieceConfidence: config.minPieceConfidence
        ) {
            return .refused(refusal)
        }

        let before = board.cells
        let baseline = Date().timeIntervalSinceReferenceDate

        // 先把所有落点算好并校验，任何一个越界都不发事件。
        var points: [Int: CGPoint] = [:]
        for index in action.changedIndices {
            guard let point = BoardTapGeometry.windowPoint(
                of: index,
                grid: grid,
                contentRect: frame.contentRect
            ), BoardTapGeometry.isTappable(point) else {
                return .refused(.offScreen)
            }
            points[index] = point
        }

        // 决策（校验、坐标换算、可点性）到此结束；剩下的都是注入开销。
        performance?.record(
            .tapDecision,
            milliseconds: PerfClock.milliseconds(since: decisionStartedAt)
        )

        phase = .tapping
        var firstIssuedAt: Double?
        var clickMilliseconds: Double = 0
        do {
            switch action {
            case .flip(let cell):
                let report = try await tap(
                    cell: cell,
                    point: points[cell] ?? .zero,
                    window: window,
                    injector: injector,
                    store: store
                )
                firstIssuedAt = report.issuedAt
                clickMilliseconds = report.clickMilliseconds
            case .move(let from, let to):
                let first = try await tap(
                    cell: from,
                    point: points[from] ?? .zero,
                    window: window,
                    injector: injector,
                    store: store
                )
                firstIssuedAt = first.issuedAt
                clickMilliseconds = first.clickMilliseconds
                try await Task.sleep(for: .seconds(config.selectDelay))
                let second = try await tap(
                    cell: to,
                    point: points[to] ?? .zero,
                    window: window,
                    injector: injector,
                    store: store
                )
                clickMilliseconds += second.clickMilliseconds
            }
        } catch {
            return .unverified("点击失败：\(error.localizedDescription)")
        }
        performance?.record(.tapClick, milliseconds: clickMilliseconds)

        // 只有自动决策才把「帧捕获 → 点击发出」记成端到端；
        // 手动按钮的等待时间属于用户思考/操作，不能混进性能验收。
        if automatic,
           let firstIssuedAt,
           let observedAt = perception.lastFrameCapturedAt,
           firstIssuedAt >= observedAt {
            performance?.record(
                .endToEnd,
                milliseconds: (firstIssuedAt - observedAt) * 1000
            )
        }

        phase = .verifying
        let deadline = Date().addingTimeInterval(config.verifyTimeout)
        var latest = board
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(config.pollInterval))
            guard let current = perception.board,
                  current.updatedAt > baseline,
                  !current.isSettling
            else { continue }
            latest = current
            if BoardTapVerifier.isSatisfied(action, before: before, after: current.cells) {
                return .confirmed(
                    changed: BoardTapVerifier.changedCount(
                        before: before, after: current.cells
                    )
                )
            }
        }

        let reason = BoardTapVerifier.mismatch(action, before: before, after: latest.cells)
        return .unverified("\(reason)（\(Int(config.verifyTimeout))s 内未出现预期变化）")
    }

    // MARK: - 单次点击

    private func tap(
        cell: Int,
        point: CGPoint,
        window: GameWindowCandidate,
        injector: InputInjector,
        store: AppStateStore
    ) async throws -> ClickReport {
        let report = try await injector.click(
            normalized: point,
            windowID: window.id,
            pid: window.ownerPID
        )
        lastWindowPoint = point
        lastAbsolutePoint = report.point
        store.note(
            "点击第 \(cell) 格 · 窗口内 \(Self.format(point)) · "
                + "屏幕 \(Int(report.point.x)),\(Int(report.point.y))"
                + (report.cursorRestored ? "（指针已还原）" : "")
        )
        return report
    }

    private static func format(_ point: CGPoint) -> String {
        String(format: "%.4f,%.4f", point.x, point.y)
    }
}
