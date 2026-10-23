import AppKit
import CoreGraphics

/// 游戏窗口匹配配置（对应 game-profile 的 window 字段；P0-1 实测后回填 shared/game-profiles）。
struct WindowMatch: Equatable, Sendable {
    var ownerName: String
    var minSize: CGSize

    /// 默认按微信小游戏 WeChatAppEx 匹配（设计文档 §2 本机实测结论）。
    static let tianTianJunQi = WindowMatch(
        ownerName: "WeChatAppEx",
        minSize: CGSize(width: 360, height: 640)
    )
}

/// CGWindowList 枚举出的候选窗口。
struct GameWindowCandidate: Identifiable, Equatable, Sendable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    /// 全局屏幕坐标（point）。
    let bounds: CGRect
}

/// 游戏窗口监测：枚举候选 + 微信运行状态。
/// 多窗口策略（逐个截图分类后让用户选择）在 M0-6 屏幕分类接入后完善；
/// M0 阶段默认取第一个候选，允许在 UI 上手动指定。
@MainActor
@Observable
final class WindowMonitor {
    private let match: WindowMatch
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    private(set) var isWeChatRunning = false
    private(set) var candidates: [GameWindowCandidate] = []

    /// 用户显式选择的窗口（多候选时）；nil 表示自动取第一个。
    var selectedWindowID: CGWindowID?

    init(match: WindowMatch = .tianTianJunQi) {
        self.match = match

        // NSWorkspace 监听微信启动/退出（设计文档 §3.1）；窗口开闭仍靠轮询
        let center = NSWorkspace.shared.notificationCenter
        let handler: (Notification) -> Void = { [weak self] note in
            // NSWorkspaceApplicationKey 常量在本 SDK 未导出到 Swift，用其原始键值
            guard let app = note.userInfo?["NSApplicationKey"] as? NSRunningApplication,
                  app.bundleIdentifier == "com.tencent.xinWeChat"
            else { return }
            self?.refresh()
        }
        observers = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil, queue: .main, using: handler
            ),
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil, queue: .main, using: handler
            ),
        ]
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    /// 当前生效的目标窗口。
    var effectiveWindowID: CGWindowID? {
        if let selectedWindowID, candidates.contains(where: { $0.id == selectedWindowID }) {
            return selectedWindowID
        }
        return candidates.first?.id
    }

    /// 重新枚举窗口与微信运行状态；由定时器与 NSWorkspace 事件驱动。
    func refresh() {
        isWeChatRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.tencent.xinWeChat"
        ).isEmpty
        candidates = Self.enumerate(match: match)
    }

    private static func enumerate(match: WindowMatch) -> [GameWindowCandidate] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else { return [] }

        return raw.compactMap { info in
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName == match.ownerName,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: NSNumber],
                  let width = boundsDict["Width"]?.doubleValue,
                  let height = boundsDict["Height"]?.doubleValue
            else { return nil }

            let bounds = CGRect(
                x: boundsDict["X"]?.doubleValue ?? 0,
                y: boundsDict["Y"]?.doubleValue ?? 0,
                width: width,
                height: height
            )

            // 尺寸过滤：排除 WeChatAppEx 的辅助小窗（悬浮窗/托盘等）
            guard bounds.width >= match.minSize.width,
                  bounds.height >= match.minSize.height
            else { return nil }

            return GameWindowCandidate(
                id: windowID,
                ownerPID: (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                ownerName: ownerName,
                // 其他进程窗口标题需要屏幕录制权限；标题只作加分项（§3.1）
                title: info[kCGWindowName as String] as? String ?? "",
                bounds: bounds
            )
        }
    }
}
