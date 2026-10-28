import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 进入流程错误。
enum ModeEntryError: LocalizedError {
    case cancelled
    case noWindow
    case noFrame
    case accessibilityUnavailable
    case blocked(String)
    case timeout(step: String, seconds: TimeInterval)
    case unknownScreen(step: String)
    case targetOffScreen(CGPoint, CGRect)
    case windowCovered(String)
    case windowTooLarge(CGSize, CGSize)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "已取消"
        case .noWindow:
            "游戏窗口不存在"
        case .noFrame:
            "没有可用的游戏画面"
        case .accessibilityUnavailable:
            "辅助功能权限未生效；请在系统设置中重新授权并重启客户端"
        case .blocked(let reason):
            reason
        case .timeout(let step, let seconds):
            "\(step)超时（\(Int(seconds))s）"
        case .unknownScreen(let step):
            "\(step)时界面无法识别（疑似未知弹窗），已暂停"
        case .targetOffScreen(let point, let bounds):
            "点击目标 (\(Int(point.x)), \(Int(point.y))) 在屏幕外；"
                + "游戏窗口 \(Int(bounds.width))×\(Int(bounds.height))，请移回屏幕内"
        case .windowCovered(let owner):
            "游戏窗口被「\(owner)」遮挡，已暂停；请把游戏窗口抬到最前"
        case .windowTooLarge(let window, let screen):
            "游戏窗口 \(Int(window.width))×\(Int(window.height)) 大于屏幕可用区域 "
                + "\(Int(screen.width))×\(Int(screen.height))，无法完整显示"
        }
    }

    /// 需要人工介入的状态 → 暂停；前置条件缺失 → 失败。
    var shouldPause: Bool {
        switch self {
        case .noWindow, .noFrame: false
        case .cancelled, .accessibilityUnavailable, .blocked, .timeout,
             .unknownScreen, .targetOffScreen, .windowCovered, .windowTooLarge: true
        }
    }
}

/// 进入翻翻棋的步骤引擎（M0-8）。
/// 实测流程：主菜单 → 场次页（点"新手场"即开始匹配真人）→ 匹配 → 棋盘 → 就绪。
/// 每步都有状态谓词、超时与重试；未知界面/超时立即暂停，不盲点。
///
/// 2026-10-23 实测补充：
/// - 窗口可被用户随时缩放/移动，因此每次点击前重新读 CGWindowList bounds；
/// - 全局点击要求目标窗口在最前，点击前 AX raise 并校验目标点最前窗口；
/// - 目标点出屏时用 AX 把窗口移回可见区域；
/// - 微信小游戏忽略 postToPid，注入使用全局点击 + 立即还原指针。
/// - 落点最终由 InputInjector 在投递前一刻按窗口 ID 重读 bounds 计算，
///   抬窗/等待期间窗口再次移动也不会点偏。
@MainActor
@Observable
final class ModeEntry {
    /// P0-2/P0-4 实测锚点；M0-10 迁移到 game-profile.json 后删除。
    /// 取大/小窗口都能覆盖的入口按钮中心区域。
    static let entryFallback = CGRect(x: 0.55, y: 0.28, width: 0.34, height: 0.18)
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
        windows: WindowMonitor,
        capture: CaptureService,
        screenState: ScreenStateService,
        injector: InputInjector,
        store: AppStateStore,
        calibration: Calibration? = nil,
        entryOnly: Bool = false
    ) async {
        guard !isRunning else { return }
        isRunning = true
        cancelRequested = false
        currentStep = nil
        lastSummary = nil

        let entryFallback = calibration?.modeEntry ?? Self.entryFallback
        let venueFallback = calibration?.buttons["venue"] ?? Self.venueFallback

        let started = Date()
        store.transition(to: .enteringMode, reason: "开始进入翻翻棋")
        if let calibration {
            store.note(
                "校准锚点已加载 · 入口 \(percent(calibration.modeEntry))"
                    + " · 场次 \(percent(calibration.buttons["venue"] ?? Self.venueFallback))"
            )
        }
        defer {
            isRunning = false
            currentStep = nil
        }

        do {
            let window = try freshWindow(windows)
            try await activate(window: window, store: store)

            var state = try await observe(capture: capture, screenState: screenState)
            store.note("步骤 1/7 识别当前界面 → \(state.label)")

            if state == .unknown {
                state = try await waitFor(
                    [.main, .modeLobby, .matching, .board, .result, .popup],
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
                        fallback: entryFallback,
                        targets: [.modeLobby, .board],
                        retries: 2, timeout: 5, step: "点击翻翻棋入口",
                        windows: windows, capture: capture, screenState: screenState,
                        injector: injector, store: store
                    )
                    // 调试模式：只验证入口点击链路，不点场次卡（不开始真人匹配）。
                    if entryOnly, state == .modeLobby {
                        store.transition(
                            to: .paused,
                            reason: "入口点击已验证，停在场次选择页（未开始匹配）"
                        )
                        lastSummary = "入口点击成功 · 未开始匹配 · \(elapsed(started))"
                        return
                    }
                }

                if state == .modeLobby {
                    state = try await clickAndWait(
                        keyword: ScreenStateService.modeLobbyKeyword,
                        fallback: venueFallback,
                        targets: [.matching, .board],
                        retries: 2, timeout: 5, step: "选择新手场",
                        windows: windows, capture: capture, screenState: screenState,
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

    /// 每次点击前都重新读窗口，适配用户中途缩放/移动。
    private func freshWindow(_ windows: WindowMonitor) throws -> GameWindowCandidate {
        windows.refresh()
        guard let window = windows.effectiveCandidate else {
            throw ModeEntryError.noWindow
        }
        return window
    }

    private func activate(window: GameWindowCandidate, store: AppStateStore) async throws {
        guard AXIsProcessTrusted() else {
            throw ModeEntryError.accessibilityUnavailable
        }
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else {
            throw ModeEntryError.noWindow
        }
        currentStep = "激活游戏窗口"
        _ = app.activate(options: [.activateAllWindows])
        raiseWindow(window)
        try await Task.sleep(for: .milliseconds(350))
        store.note("步骤 0/7 激活游戏窗口 · \(app.localizedName ?? window.ownerName)")
    }

    /// 点击关键字中心（找不到就用实测锚点），然后等待目标界面。
    private func clickAndWait(
        keyword: String,
        fallback: CGRect,
        targets: Set<ScreenState>,
        retries: Int,
        timeout: TimeInterval,
        step: String,
        windows: WindowMonitor,
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
            if cancelRequested { throw ModeEntryError.cancelled }

            var window = try freshWindow(windows)
            window = try await ensureWindowOnScreen(window, windows: windows, store: store)
            raiseWindow(window)
            try await Task.sleep(for: .milliseconds(250))

            let rect = screenState.locate(keyword) ?? fallback
            // 抬窗与等待期间窗口仍可能被移动：校验和落点都用最新 bounds，
            // 不能沿用上面 freshWindow 读到的旧坐标。
            func absolutePoint(in bounds: CGRect) -> CGPoint {
                CGPoint(
                    x: bounds.minX + rect.midX * bounds.width,
                    y: bounds.minY + rect.midY * bounds.height
                )
            }
            guard let bounds = WindowGeometry.frame(of: window.id) else {
                throw ModeEntryError.noWindow
            }
            var point = absolutePoint(in: bounds)
            guard InputInjector.isOnScreen(point) else {
                throw ModeEntryError.targetOffScreen(point, bounds)
            }

            // 全局点击会命中“目标点最上面的窗口”；若游戏被盖住，先 raise 再复核。
            if let top = WindowGeometry.topWindow(at: point), top.id != window.id {
                raiseWindow(window)
                try await Task.sleep(for: .milliseconds(250))
                guard let raised = WindowGeometry.frame(of: window.id) else {
                    throw ModeEntryError.noWindow
                }
                point = absolutePoint(in: raised)
                guard InputInjector.isOnScreen(point) else {
                    throw ModeEntryError.targetOffScreen(point, raised)
                }
                if let again = WindowGeometry.topWindow(at: point), again.id != window.id {
                    throw ModeEntryError.windowCovered(again.owner)
                }
            }

            currentStep = "\(step)（第 \(attempt + 1) 次）"
            let report = try await injector.click(
                normalized: CGPoint(x: rect.midX, y: rect.midY),
                windowID: window.id,
                pid: window.ownerPID
            )
            store.note(
                "步骤「\(step)」第 \(attempt + 1) 次点击 \(keyword) · "
                    + "窗口 \(Int(report.windowBounds.minX)),\(Int(report.windowBounds.minY)) "
                    + "\(Int(report.windowBounds.width))×\(Int(report.windowBounds.height)) · "
                    + "目标 \(Int(report.point.x)),\(Int(report.point.y)) · "
                    + (report.delivery == .process ? "后台事件" : "全局点击")
                    + (report.cursorRestored ? "（指针已还原）" : "")
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

    // MARK: - Window geometry

    /// 窗口有一部分在屏幕外时，用 AX 把它移回可见区域。
    private func ensureWindowOnScreen(
        _ window: GameWindowCandidate,
        windows: WindowMonitor,
        store: AppStateStore
    ) async throws -> GameWindowCandidate {
        guard let available = bestScreen(for: window.bounds) else { return window }
        guard window.bounds.width <= available.width,
              window.bounds.height <= available.height
        else {
            throw ModeEntryError.windowTooLarge(window.bounds.size, available.size)
        }
        if available.contains(window.bounds) { return window }

        guard let axWindow = axWindow(for: window) else {
            throw ModeEntryError.blocked("游戏窗口在屏幕外，且无法通过 AX 移动；请手动移回屏幕内")
        }
        var origin = CGPoint(x: available.minX, y: available.minY)
        guard let value = AXValueCreate(.cgPoint, &origin) else {
            throw ModeEntryError.blocked("无法创建窗口位置 AXValue")
        }
        let result = AXUIElementSetAttributeValue(
            axWindow, kAXPositionAttribute as CFString, value
        )
        guard result == .success else {
            throw ModeEntryError.blocked("移动游戏窗口失败（AX 错误 \(result.rawValue)）")
        }

        try await Task.sleep(for: .milliseconds(300))
        windows.refresh()
        guard let updated = windows.effectiveCandidate else {
            throw ModeEntryError.noWindow
        }
        store.note("游戏窗口超出屏幕，已移动到 \(Int(origin.x)), \(Int(origin.y))")
        return updated
    }

    /// 返回与窗口交集最大的屏幕可用区域（左上原点全局坐标）。
    private func bestScreen(for window: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        guard let main = screens.first else { return nil }
        let mainHeight = main.frame.height

        return screens
            .map { screen -> (CGRect, CGFloat) in
                let ns = screen.visibleFrame
                let rect = CGRect(
                    x: ns.minX,
                    y: mainHeight - ns.maxY,
                    width: ns.width,
                    height: ns.height
                )
                let intersection = rect.intersection(window)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                return (rect, area)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    /// 通过 AX 找到目标窗口：优先标题，其次位置/尺寸（标题为空时）。
    private func axWindow(for window: GameWindowCandidate) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &value
        ) == .success,
              let axWindows = value as? [AXUIElement]
        else { return nil }

        var fallback: AXUIElement?
        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String ?? ""

            if title == window.title { return axWindow }
            if fallback == nil, title.contains("天天军棋") { fallback = axWindow }
            if fallback == nil, let frame = axFrame(axWindow),
               abs(frame.minX - window.bounds.minX) < 4,
               abs(frame.minY - window.bounds.minY) < 4,
               abs(frame.width - window.bounds.width) < 4,
               abs(frame.height - window.bounds.height) < 4 {
                fallback = axWindow
            }
        }
        return fallback
    }

    @discardableResult
    private func raiseWindow(_ window: GameWindowCandidate) -> Bool {
        guard let axWindow = axWindow(for: window) else { return false }
        return AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) == .success
    }

    private func axFrame(_ axWindow: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axWindow, kAXPositionAttribute as CFString, &positionRef
        ) == .success,
              AXUIElementCopyAttributeValue(
                axWindow, kAXSizeAttribute as CFString, &sizeRef
              ) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
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

    private func percent(_ rect: CGRect) -> String {
        "\(Int(rect.minX * 100)),\(Int(rect.minY * 100)) "
            + "\(Int(rect.width * 100))×\(Int(rect.height * 100))%"
    }
}
