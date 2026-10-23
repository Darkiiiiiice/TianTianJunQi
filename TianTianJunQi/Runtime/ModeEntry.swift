import AppKit
import ApplicationServices
import Foundation

/// 进入流程错误。
enum ModeEntryError: LocalizedError {
    case cancelled
    case noWindow
    case noFrame
    case blocked(String)
    case timeout(step: String, seconds: TimeInterval)
    case unknownScreen(step: String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "已取消"
        case .noWindow:
            "游戏窗口不存在"
        case .noFrame:
            "没有可用的游戏画面"
        case .blocked(let reason):
            reason
        case .timeout(let step, let seconds):
            "\(step)超时（\(Int(seconds))s）"
        case .unknownScreen(let step):
            "\(step)时界面无法识别（疑似未知弹窗），已暂停"
        }
    }

    /// 需要人工介入的状态 → 暂停；前置条件缺失 → 失败。
    var shouldPause: Bool {
        switch self {
        case .noWindow, .noFrame: false
        case .cancelled, .blocked, .timeout, .unknownScreen: true
        }
    }
}

/// 进入翻翻棋的步骤引擎（M0-8）。
/// 实测流程：主菜单 → 场次页（点"新手场"即开始匹配真人）→ 匹配 → 棋盘 → 就绪。
/// 每步都有状态谓词、超时与重试；未知界面/超时立即暂停，不盲点。
@MainActor
@Observable
final class ModeEntry {
    /// P0-2/P0-4 实测锚点；M0-10 迁移到 game-profile.json 后删除。
    static let entryFallback = CGRect(x: 0.52, y: 0.26, width: 0.33, height: 0.17)
    static let venueFallback = CGRect(x: 0.235, y: 0.184, width: 0.185, height: 0.673)
    /// 真人匹配等待上限（P0-4：确实可能等很久；超时暂停，不重复点击）。
    static let matchTimeout: TimeInterval = 120

    private(set) var isRunning = false
    private(set) var currentStep: String?
    private(set) var lastSummary: String?

    private var cancelRequested = false

    /// 急停/取消：只置标志，循环在下一个检查点退出。
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        currentStep = "正在取消…"
    }

    func enter(
        window: GameWindowCandidate,
        capture: CaptureService,
        screenState: ScreenStateService,
        injector: InputInjector,
        store: AppStateStore
    ) async {
        guard !isRunning else { return }
        isRunning = true
        cancelRequested = false
        currentStep = nil
        lastSummary = nil

        let started = Date()
        store.transition(to: .enteringMode, reason: "开始进入翻翻棋")
        defer {
            isRunning = false
            currentStep = nil
        }

        do {
            try await activate(window: window, store: store)

            var state = try await observe(capture: capture, screenState: screenState)
            store.note("步骤 1/7 识别当前界面 → \(state.label)")

            if state == .unknown {
                state = try await waitFor(
                    [.main, .venue, .matching, .board, .result, .popup],
                    timeout: 5, step: "等待界面稳定",
                    capture: capture, screenState: screenState, store: store
                )
            }

            if state == .board {
                store.transition(to: .ready, reason: "已在牌局，跳过入口点击")
                lastSummary = "已在牌局 · \(elapsed(started))"
                return
            }
            if state == .result {
                throw ModeEntryError.blocked("当前在结算页，请手动选择再来一局/切换对手")
            }
            if state == .popup {
                throw ModeEntryError.blocked("检测到规则/公告弹窗，已暂停；请手动关闭后重试")
            }

            if state == .matching {
                store.transition(to: .matching, reason: "已在匹配中，等待牌局")
                state = try await waitFor(
                    [.board], timeout: Self.matchTimeout, step: "等待匹配",
                    capture: capture, screenState: screenState, store: store
                )
            } else {
                if state == .main {
                    state = try await clickAndWait(
                        keyword: ScreenStateService.mainKeyword,
                        fallback: Self.entryFallback,
                        targets: [.venue, .board],
                        retries: 2, timeout: 5, step: "点击翻翻棋入口",
                        window: window, capture: capture, screenState: screenState,
                        injector: injector, store: store
                    )
                }

                if state == .venue {
                    state = try await clickAndWait(
                        keyword: ScreenStateService.venueKeyword,
                        fallback: Self.venueFallback,
                        targets: [.matching, .board],
                        retries: 2, timeout: 5, step: "选择新手场",
                        window: window, capture: capture, screenState: screenState,
                        injector: injector, store: store
                    )
                }

                if state == .matching {
                    store.transition(to: .matching, reason: "已发起真人匹配，等待牌局")
                    state = try await waitFor(
                        [.board], timeout: Self.matchTimeout, step: "等待匹配",
                        capture: capture, screenState: screenState, store: store
                    )
                }
            }

            guard state == .board else {
                throw ModeEntryError.unknownScreen(step: "进入牌局")
            }

            // 棋盘稳定：避开入场动画，连续两次识别为 board 才算就绪。
            try await Task.sleep(for: .milliseconds(700))
            let stable = try await observe(capture: capture, screenState: screenState)
            guard stable == .board else {
                throw ModeEntryError.unknownScreen(step: "确认棋盘稳定")
            }

            store.transition(to: .ready, reason: "牌局就绪 · \(elapsed(started))")
            lastSummary = "已进入牌局 · \(elapsed(started))"
        } catch let error as ModeEntryError {
            finish(error, store: store, started: started)
        } catch is CancellationError {
            finish(.cancelled, store: store, started: started)
        } catch {
            finish(.blocked(error.localizedDescription), store: store, started: started)
        }
    }

    // MARK: - Steps

    private func activate(window: GameWindowCandidate, store: AppStateStore) async throws {
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else {
            throw ModeEntryError.noWindow
        }
        currentStep = "激活游戏窗口"
        app.activate(from: .current, options: [])
        raiseWindow(window)
        try await Task.sleep(for: .milliseconds(350))
        store.note("步骤 0/7 激活游戏窗口 · \(app.localizedName ?? window.ownerName)")
    }

    /// 把目标窗口抬到最前；activate 只保证应用在前台，不一定抬对窗口。
    private func raiseWindow(_ window: GameWindowCandidate) {
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement]
        else { return }

        for axWindow in axWindows {
            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)
            guard (titleValue as? String) == window.title else { continue }
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            return
        }
    }

    /// 点击关键字中心（找不到就用实测锚点），然后等待目标界面。
    private func clickAndWait(
        keyword: String,
        fallback: CGRect,
        targets: Set<ScreenState>,
        retries: Int,
        timeout: TimeInterval,
        step: String,
        window: GameWindowCandidate,
        capture: CaptureService,
        screenState: ScreenStateService,
        injector: InputInjector,
        store: AppStateStore
    ) async throws -> ScreenState {
        var state = try await observe(capture: capture, screenState: screenState)

        for attempt in 0...retries {
            if targets.contains(state) { return state }
            if state == .popup {
                throw ModeEntryError.blocked("步骤「\(step)」遇到弹窗，已暂停；请手动关闭后重试")
            }

            let rect = screenState.locate(keyword) ?? fallback
            currentStep = "\(step)（第 \(attempt + 1) 次）"
            store.note(
                "步骤「\(step)」第 \(attempt + 1) 次点击 \(keyword) · "
                    + String(format: "中心(%.2f, %.2f)", rect.midX, rect.midY)
            )
            try await injector.click(
                normalized: CGPoint(x: rect.midX, y: rect.midY),
                in: window.bounds
            )

            do {
                return try await waitFor(
                    targets, timeout: timeout, step: step,
                    capture: capture, screenState: screenState, store: store
                )
            } catch let error as ModeEntryError {
                guard case .timeout = error, attempt < retries else { throw error }
                store.note("步骤「\(step)」超时，准备重试（\(attempt + 2)/\(retries + 1)）")
                state = try await observe(capture: capture, screenState: screenState)
            }
        }

        throw ModeEntryError.timeout(step: step, seconds: timeout)
    }

    /// 轮询目标状态；未知界面持续 5s 视为未知弹窗并暂停。
    private func waitFor(
        _ targets: Set<ScreenState>,
        timeout: TimeInterval,
        step: String,
        capture: CaptureService,
        screenState: ScreenStateService,
        store: AppStateStore
    ) async throws -> ScreenState {
        let deadline = Date().addingTimeInterval(timeout)
        var unknownSince: Date?
        var lastReported: ScreenState?

        while Date() < deadline {
            if cancelRequested { throw ModeEntryError.cancelled }

            let state = try await observe(capture: capture, screenState: screenState)
            if targets.contains(state) { return state }
            if state == .popup {
                throw ModeEntryError.blocked("步骤「\(step)」遇到弹窗，已暂停；请手动关闭后重试")
            }
            if state == .unknown {
                if unknownSince == nil { unknownSince = Date() }
                if let start = unknownSince, Date().timeIntervalSince(start) > 5 {
                    throw ModeEntryError.unknownScreen(step: step)
                }
            } else {
                unknownSince = nil
                if state != lastReported {
                    store.note("步骤「\(step)」当前界面 → \(state.label)")
                    lastReported = state
                }
            }

            try await Task.sleep(for: .milliseconds(600))
        }

        throw ModeEntryError.timeout(step: step, seconds: timeout)
    }

    /// 取最新帧做一次强制 OCR，返回界面状态。
    private func observe(
        capture: CaptureService,
        screenState: ScreenStateService
    ) async throws -> ScreenState {
        for _ in 0..<10 {
            if cancelRequested { throw ModeEntryError.cancelled }
            if let frame = capture.latestFrame {
                await screenState.analyzeIfNeeded(frame: frame, minInterval: 0)
                return screenState.state
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw ModeEntryError.noFrame
    }

    private func finish(_ error: ModeEntryError, store: AppStateStore, started: Date) {
        if error.shouldPause {
            store.transition(to: .paused, reason: error.localizedDescription)
        } else {
            store.transition(to: .failed, reason: error.localizedDescription)
        }
        lastSummary = "\(error.localizedDescription) · \(elapsed(started))"
    }

    private func elapsed(_ start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }
}
