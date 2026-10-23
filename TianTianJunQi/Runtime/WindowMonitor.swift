import AppKit
import CoreGraphics

/// 游戏窗口匹配配置（对应 game-profile 的 window 字段；P0-1 实测后回填 shared/game-profiles）。
struct WindowMatch: Equatable, Sendable {
    /// 候选窗口的 owner 进程 bundle 集合。
    /// 本机实测：小游戏窗口由主微信进程持有（WeChatAppEx 只渲染、名下无窗口），
    /// 两者都放进候选池，由标题命中决定目标。
    var ownerBundleIDs: [String]
    /// 标题命中关键字（强信号；窗口标题需要屏幕录制权限）。
    var titleContains: [String]
    /// 最小尺寸：排除悬浮条/托盘等辅助小窗。
    var minSize: CGSize

    /// 默认按腾讯天天军棋匹配（P0-1 实测：title=腾讯天天军棋，929x567，owner=主微信进程）。
    static let tianTianJunQi = WindowMatch(
        ownerBundleIDs: ["com.tencent.xinWeChat", "com.tencent.flue.WeChatAppEx"],
        titleContains: ["天天军棋"],
        minSize: CGSize(width: 300, height: 300)
    )
}

/// CGWindowList 枚举出的候选窗口。
struct GameWindowCandidate: Identifiable, Equatable, Sendable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let bundleID: String
    let title: String
    /// 全局屏幕坐标（point）。
    let bounds: CGRect
}

/// 游戏窗口监测：枚举候选 + 微信运行状态。
/// 多窗口策略（逐个截图分类后让用户选择）在 M0-6 屏幕分类接入后完善；
/// 当前优先标题命中，其次 WeChatAppEx 自有窗口，允许在 UI 上手动指定。
@MainActor
@Observable
final class WindowMonitor {
    private static let mainAppBundleID = "com.tencent.xinWeChat"

    private let match: WindowMatch
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    private(set) var isWeChatRunning = false
    private(set) var candidates: [GameWindowCandidate] = []

    /// 用户显式选择的窗口（多候选时）；nil 表示自动。
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
        effectiveCandidate?.id
    }

    /// 自动选择的目标候选：标题命中 > WeChatAppEx 自有窗口。
    var effectiveCandidate: GameWindowCandidate? {
        if let selectedWindowID, let picked = candidates.first(where: { $0.id == selectedWindowID }) {
            return picked
        }
        // 标题命中优先（P0-1 实测：主微信进程持有游戏窗口，标题"腾讯天天军棋"）
        if let titleHit = candidates.first(where: { candidate in
            match.titleContains.contains { candidate.title.contains($0) }
        }) {
            return titleHit
        }
        // 兜底：其他微信版本可能把窗口挂在渲染进程（WeChatAppEx）名下
        let rendererOwned = candidates.first { $0.bundleID != Self.mainAppBundleID }
        return rendererOwned
    }

    /// 重新枚举窗口与微信运行状态；由定时器与 NSWorkspace 事件驱动。
    func refresh() {
        isWeChatRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.mainAppBundleID
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
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0, // 普通窗口；排除悬浮条/托盘等特殊层
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

            // 尺寸过滤：排除辅助小窗
            guard bounds.width >= match.minSize.width,
                  bounds.height >= match.minSize.height
            else { return nil }

            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            guard match.ownerBundleIDs.contains(bundleID) else { return nil }

            return GameWindowCandidate(
                id: windowID,
                ownerPID: pid,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                bundleID: bundleID,
                // 窗口标题需要屏幕录制权限；标题是本方案的强判定信号（P0-1 实测）
                title: info[kCGWindowName as String] as? String ?? "",
                bounds: bounds
            )
        }
    }
}
