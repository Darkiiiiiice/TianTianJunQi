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

            SettingsView(permissions: permissions)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Page.settings)
        }
        .onAppear {
            permissions.refresh()
            windows.refresh()
            syncCapture()
            updateRuntimeState()
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
