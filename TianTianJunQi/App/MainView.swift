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
    @State private var selection: Page = .overview

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
                capture: capture, screenState: screenState,
                onEnterMode: { Task { await enterMode() } }
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
        guard permissions.allGranted, let windowID = windows.effectiveWindowID else {
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

    /// 进入翻翻棋（M0-6/M0-7 链路验证）：OCR 定位入口 → 单次点击注入。
    /// 完整 9 步步骤引擎（谓词校验/重试/弹窗处理）在 M0-8 落地。
    private func enterMode() async {
        guard let window = windows.effectiveCandidate, let frame = capture.latestFrame else { return }
        await screenState.analyzeIfNeeded(frame: frame, minInterval: 0)
        guard let entry = screenState.entryRect else {
            store.transition(to: .failed, reason: "进入失败：OCR 未定位到翻翻棋入口")
            return
        }
        do {
            try await injector.click(
                normalized: CGPoint(x: entry.midX, y: entry.midY),
                in: window.bounds
            )
            store.transition(to: .enteringMode, reason: "已点击入口，等待模式页（验证点）")
        } catch {
            store.transition(to: .failed, reason: "点击注入失败：\(error.localizedDescription)")
        }
    }
}
