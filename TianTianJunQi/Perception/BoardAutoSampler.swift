import CoreGraphics
import Foundation
import Observation

/// 对局中「棋盘棋子变化 → 自动保存一份样本」的服务。
///
/// 只在对局界面工作；用缩小后的棋盘区域指纹判断变化，静止后整帧 + 60 格落盘。
/// 保存前会确认界面仍是牌局（结算/弹窗不采），并把快照标记为 `origin = "auto"`。
@MainActor
@Observable
final class BoardAutoSampler {
    enum Phase: Equatable, Sendable {
        case off
        case waitingForBoard
        case watching
        case settling
        case saving
        case paused(String)
        case failed(String)
    }

    private static let enabledKey = "perception.autoSample.enabled"

    private(set) var phase: Phase = .off
    /// 本次启动累计保存份数。
    private(set) var capturedCount = 0
    /// 当前这一局累计保存份数。
    private(set) var capturedThisGame = 0
    private(set) var lastSavedAt: Date?
    private(set) var lastSnapshotID: String?

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled {
                inGame = false
                tracker.reset()
                phase = .off
            }
        }
    }

    var config = BoardAutoSamplerConfig()

    @ObservationIgnored private var tracker: BoardAutoSampleTracker
    @ObservationIgnored private var inGame = false
    @ObservationIgnored private var exporting = false

    init(config: BoardAutoSamplerConfig = BoardAutoSamplerConfig()) {
        self.config = config
        self.tracker = BoardAutoSampleTracker(config: config)
        let stored = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
        self.isEnabled = stored ?? true
        self.phase = isEnabled ? .waitingForBoard : .off
    }

    var statusText: String {
        guard isEnabled else { return "自动采样已关闭" }
        switch phase {
        case .off:
            return "自动采样已关闭"
        case .waitingForBoard:
            return "自动采样 · 等待进入牌局…"
        case .watching:
            if capturedCount == 0 {
                return "自动采样 · 等待棋子变化…"
            }
            return "自动采样 · 本次已存 \(capturedCount) 份"
                + "（本局 \(capturedThisGame)）"
                + (lastSavedAt.map { " · 最近 \(Self.timeText($0))" } ?? "")
        case .settling:
            return "自动采样 · 棋盘变化，等待稳定…"
        case .saving:
            return "自动采样 · 正在保存样本…"
        case .paused(let reason):
            return "自动采样 · \(reason)"
        case .failed(let message):
            return "自动采样失败：\(message)"
        }
    }

    /// 常驻循环；由 MainView 的 `.task` 持有，视图销毁时自动取消。
    func run(
        capture: CaptureService,
        calibration: CalibrationStore,
        windows: WindowMonitor,
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
                inGame = false
                tracker.reset()
                continue
            }
            guard !exporting else { continue }

            let now = Date()
            syncSession(state: screenState.state, now: now.timeIntervalSinceReferenceDate)
            guard inGame else {
                phase = .waitingForBoard
                continue
            }
            if tracker.gameCaptureCount >= config.maxPerGame {
                phase = .paused("本局已存 \(tracker.gameCaptureCount) 份，下一局继续")
                continue
            }
            // 开局横幅（翻旗定阵营 / 对局正式开始）压着棋盘中间，等它消失再采，避免格子被挡住。
            if screenState.showsBoardBanner {
                phase = .watching
                continue
            }

            guard let calibrationValue = calibration.calibration,
                  let grid = calibrationValue.boardGrid(rows: rows, cols: cols),
                  let frame = capture.latestFrame
            else {
                tracker.reset()
                phase = .waitingForBoard
                continue
            }

            let width = config.probeWidth
            let probe = await Task.detached(priority: .utility) { () -> BoardFingerprint? in
                guard let image = try? BoardSnapshotExporter.contentImage(from: frame) else {
                    return nil
                }
                return BoardChangeDetector.fingerprint(image: image, width: width)
            }.value
            guard let probe else {
                tracker.reset()
                continue
            }

            let action = tracker.observe(
                probe,
                cellBoxes: BoardCellBox.grid(
                    rows: grid.rows,
                    cols: grid.cols,
                    rects: grid.cellBoundingRects(),
                    probeWidth: probe.width,
                    probeHeight: probe.height
                ),
                boardCorners: grid.quad.corners,
                at: Date().timeIntervalSinceReferenceDate
            )
            switch action {
            case .waiting, .unchanged:
                phase = .watching
            case .settling:
                phase = .settling
            case .limitReached:
                phase = .paused("本局已存 \(tracker.gameCaptureCount) 份，下一局继续")
            case .capture(let change):
                store.note(
                    "检测到走棋：\(change.changedCells) 格变化，"
                        + "最大单格 \(Int(change.maxCellFraction * 100))%"
                )
                await captureIfStillOnBoard(
                    changed: change.boardFraction,
                    probe: probe,
                    frame: frame,
                    grid: grid,
                    calibration: calibrationValue,
                    windows: windows,
                    screenState: screenState,
                    store: store
                )
            }
        }
    }

    // MARK: - 内部

    private func syncSession(state: ScreenState, now: TimeInterval) {
        switch state {
        case .board:
            if !inGame {
                inGame = true
                tracker.beginGame()
                capturedThisGame = 0
                phase = .watching
            }
        case .main, .modeLobby, .matching, .result, .popup:
            if inGame {
                inGame = false
                capturedThisGame = 0
            }
            tracker.reset()
        case .unknown:
            // OCR 偶尔会漏识别；保持当前对局会话，避免把同一局切成“新局”。
            break
        }
    }

    /// 保存前确认界面仍是牌局：大变化/状态过期时强制重新 OCR，结算页与弹窗一律不采。
    private func captureIfStillOnBoard(
        changed: Double,
        probe: BoardFingerprint,
        frame: CapturedFrame,
        grid: BoardGrid,
        calibration: Calibration,
        windows: WindowMonitor,
        screenState: ScreenStateService,
        store: AppStateStore
    ) async {
        let now = Date()
        let ocrAge = screenState.lastOCRAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let needsFreshOCR = screenState.state != .board
            || ocrAge > config.screenStateMaxAge
            || changed >= config.largeChange
        if needsFreshOCR {
            await screenState.analyzeIfNeeded(frame: frame, minInterval: 0)
            guard screenState.state == .board else {
                tracker.reset()
                syncSession(
                    state: screenState.state,
                    now: Date().timeIntervalSinceReferenceDate
                )
                phase = inGame ? .watching : .waitingForBoard
                return
            }
        }

        exporting = true
        phase = .saving
        let windowSize = windows.effectiveCandidate?.bounds.size
        let theme = calibration.theme

        do {
            let url = try await Task.detached(priority: .utility) {
                try BoardSnapshotExporter().export(
                    frame: frame,
                    grid: grid,
                    windowSize: windowSize,
                    theme: theme,
                    origin: "auto"
                )
            }.value
            tracker.recordCapture(probe, at: Date().timeIntervalSinceReferenceDate)
            capturedCount += 1
            capturedThisGame += 1
            lastSavedAt = Date()
            lastSnapshotID = url.lastPathComponent
            phase = .watching
            store.note("自动采样已保存：\(url.lastPathComponent)")
        } catch {
            phase = .failed(error.localizedDescription)
            store.note("自动采样失败：\(error.localizedDescription)")
        }
        exporting = false
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
