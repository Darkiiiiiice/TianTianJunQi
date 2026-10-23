import AppKit
import ApplicationServices
import CoreGraphics

/// 需要用户授权的系统权限（设计文档 §9.6：权限检查放在最前面，缺一个后面都会以难以定位的方式失败）。
enum PermissionKind: String, CaseIterable, Sendable {
    /// 屏幕录制：SCStream 抓取 WeChatAppEx 游戏窗口画面（M0-5）。
    case screenRecording
    /// 辅助功能：窗口 raise 与 CGEvent 注入的前置（M0-4/M0-7）。
    case accessibility
    /// 输入监控：CGEventTap 监听人类示范操作（M2-8）。
    case inputMonitoring

    var label: String {
        switch self {
        case .screenRecording: "屏幕录制"
        case .accessibility: "辅助功能"
        case .inputMonitoring: "输入监控"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: "抓取游戏窗口画面用于感知"
        case .accessibility: "激活窗口与注入鼠标事件"
        case .inputMonitoring: "录制人类示范时监听鼠标"
        }
    }

    /// 对应"系统设置 → 隐私与安全性"面板深链。
    var settingsURL: URL {
        let pane = switch self {
        case .screenRecording: "com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility: "com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring: "com.apple.preference.security?Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:\(pane)")!
    }
}

/// 三项权限的预检、请求与设置面板跳转。只调系统 API：预检无提示，请求由系统弹窗/跳转。
enum PermissionCenter {
    /// 无提示预检，只返回当前授权状态。
    static func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        }
    }

    /// 发起授权请求（系统弹窗；部分系统版本会直接引导到设置面板）。
    static func request(_ kind: PermissionKind) {
        switch kind {
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
        case .accessibility:
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        case .inputMonitoring:
            if !CGPreflightListenEventAccess() {
                _ = CGRequestListenEventAccess()
                // 系统弹窗只在首次请求时出现；部分版本/“已询问”状态下不弹。
                // 实际创建一次性 listen-only tap 是更可靠的触发方式（M2-8 之外的常规做法）。
                triggerListenProbe()
            }
        }
    }

    /// 创建一次性 listen-only 事件 tap 触发系统授权弹窗；不加入 run loop，创建即销毁。
    private static func triggerListenProbe() {
        let mask = CGEventMask(
            (1 << CGEventType.mouseMoved.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.scrollWheel.rawValue)
        )
        // 本 SDK 的 apinotes 把 CGEventTapCreate 重命名为 CGEvent.tapCreate，
        // 且未导出 CGEventTapLocation 等 C 枚举的 Swift case 名，用头文件中的原始值：
        // kCGSessionEventTap = 1、kCGHeadInsertEventTap = 0、kCGEventTapOptionListenOnly = 1
        guard let tap = CGEvent.tapCreate(
            tap: CGEventTapLocation(rawValue: 1)!,
            place: CGEventTapPlacement(rawValue: 0)!,
            options: CGEventTapOptions(rawValue: 1)!,
            eventsOfInterest: mask,
            callback: probeTapCallback,
            userInfo: nil
        ) else { return }
        CFMachPortInvalidate(tap)
    }

    /// 无捕获的 C 回调（tap 不会进 run loop，实际不会被调用）。
    private static let probeTapCallback: CGEventTapCallBack = { _, _, event, _ in
        Unmanaged.passUnretained(event)
    }

    /// 打开对应系统设置面板（请求弹窗被忽略或授权失效复查后的兜底入口）。
    static func openSettings(_ kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
