import Combine
import SwiftUI

/// 单窗口主界面：概览 / 训练 / 日志 / 设置（设计文档 §3.2）。
struct MainView: View {
    @State private var store = AppStateStore()
    @State private var permissions = PermissionStore()
    @State private var windows = WindowMonitor()
    @State private var capture = CaptureService()
    @State private var screenState = ScreenStateService()
    @State private var injector = InputInjector()
    @State private var modeEntry = ModeEntry()
    @State private var calibration = CalibrationStore()
    @State private var autoSampler = BoardAutoSampler()
    @State private var perception = BoardPerceptionService()
    @State private var tapService = BoardTapService()
    /// M1-9：实时延迟采样，供概览页与报告导出使用。
    @State private var performance = PerformanceMonitor()
    @State private var gameProfile = GameProfile.tianTianJunQi
    @State private var selection: Page = .overview
    /// 调试开关：只验证入口点击，不点场次卡（不开始真人匹配）。
    @State private var entryOnly = false

    /// 周期复查定时器：授权失效检测（设计文档 §9.6）。
    @State private var permissionTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    /// 窗口轮询定时器：WeChatAppEx 窗口开闭没有系统通知，靠轻量轮询。
    @State private var windowTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    enum Page: Hashable {
        case overview
        case training
        case logs
        case settings
    }

    var body: some View {
        TabView(selection: $selection) {
            OverviewView(
                store: store, permissions: permissions, windows: windows,
                capture: capture, screenState: screenState, modeEntry: modeEntry,
                calibration: calibration, autoSampler: autoSampler,
                perception: perception,
                tapService: tapService, injector: injector,
                performance: performance,
                boardRows: gameProfile.board.rows,
                boardCols: gameProfile.board.cols,
                entryOnly: $entryOnly,
                onEnterMode: { Task { await enterMode() } },
                onPause: { pause(reason: "用户暂停") },
                onEmergencyStop: { pause(reason: "用户急停") }
            )
            .tabItem { Label("概览", systemImage: "gauge.with.needle") }
            .tag(Page.overview)

            TrainingView()
                .tabItem { Label("训练", systemImage: "brain.head.profile") }
                .tag(Page.training)

            LogsView(store: store)
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }
                .tag(Page.logs)

            SettingsView(
                permissions: permissions,
                calibration: calibration,
                windows: windows,
                capture: capture
            )
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(Page.settings)
        }
        .onAppear {
            // M1-9：各服务只记录，不改变感知/动作行为。
            screenState.performance = performance
            perception.performance = performance
            tapService.performance = performance
            permissions.refresh()
            windows.refresh()
            syncCapture()
            updateRuntimeState()
            initStorage()
        }
        .onReceive(permissionTimer) { _ in
            permissions.refresh()
            syncCapture()
        }
        .onReceive(windowTimer) { _ in
            windows.refresh()
            syncCapture()
            updateRuntimeState()
            // 窗口被用户缩放后同步抓帧基准尺寸（scale 换算用）。
            if let candidate = windows.effectiveCandidate {
                capture.updateWindowSize(candidate.bounds.size)
            }
            if let frame = capture.latestFrame {
                Task { await screenState.analyzeIfNeeded(frame: frame) }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            permissions.refresh()
        }
        .task {
            // M1-7：启动即加载并预热 Core ML 屏幕分类器；失败自动退回 OCR。
            await screenState.prepare()
        }
        .task {
            // 常驻对局自动采样：视图销毁时取消。
            await autoSampler.run(
                capture: capture,
                calibration: calibration,
                windows: windows,
                screenState: screenState,
                store: store,
                rows: gameProfile.board.rows,
                cols: gameProfile.board.cols
            )
        }
        .task {
            // M1-4：常驻棋局感知，分类器 → 时序平滑 → 稳定棋盘。
            await perception.run(
                capture: capture,
                calibration: calibration,
                screenState: screenState,
                store: store,
                rows: gameProfile.board.rows,
                cols: gameProfile.board.cols
            )
        }
    }

    /// M0-10：启动即建 Application Support 目录布局，并确保 `game-profile.json` 存在。
    private func initStorage() {
        do {
            let storage = StorageKit()
            try storage.ensureLayout()
            gameProfile = try storage.loadOrCreateGameProfile()
            store.note("存储目录就绪：\(storage.rootURL.path)")
        } catch {
            store.note("存储初始化失败：\(error.localizedDescription)")
        }
    }

    /// 根据权限与窗口检测结果同步抓帧目标。
    private func syncCapture() {
        guard permissions.controlReady, let windowID = windows.effectiveWindowID else {
            if capture.isCapturing {
                Task { await capture.stop() }
            }
            return
        }
        Task { await capture.startOrSwitch(to: windowID) }
    }

    /// 把窗口检测结果映射到状态机（设计文档 §4：启动 → 游戏窗口检查）。
    private func updateRuntimeState() {
        if !windows.isWeChatRunning {
            store.transition(to: .waitingWindow, reason: "微信未运行")
        } else if windows.effectiveWindowID == nil {
            store.transition(to: .waitingWindow, reason: "游戏窗口未打开")
        } else if store.state == .waitingWindow {
            store.transition(to: .idle, reason: "游戏窗口已检测")
        } else if store.state == .failed {
            store.transition(to: .idle, reason: "失败后恢复")
        }
    }

    /// 进入翻翻棋（M0-8）：激活窗口 → 主菜单 → 场次页 → 新手场 → 匹配 → 棋盘。
    /// 真人匹配：进入后按用户配置执行；未知界面/超时暂停，不盲点。
    private func enterMode() async {
        windows.refresh()
        guard windows.effectiveCandidate != nil else {
            store.transition(to: .failed, reason: "进入失败：游戏窗口不存在")
            return
        }
        await modeEntry.enter(
            windows: windows,
            capture: capture,
            screenState: screenState,
            injector: injector,
            store: store,
            calibration: calibration.calibration,
            entryOnly: entryOnly
        )
    }

    /// 暂停/急停：取消进入流程并进入暂停态。
    private func pause(reason: String) {
        modeEntry.cancel()
        if !modeEntry.isRunning {
            store.transition(to: .paused, reason: reason)
        }
    }
}
