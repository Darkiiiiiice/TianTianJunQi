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
    /// minSize 放宽到 240x180：小游戏窗口可被用户缩到 368x251，原 300 高度会漏检。
    static let tianTianJunQi = WindowMatch(
        ownerBundleIDs: ["com.tencent.xinWeChat", "com.tencent.flue.WeChatAppEx"],
        titleContains: ["天天军棋"],
        minSize: CGSize(width: 240, height: 180)
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

/// 窗口几何查询（点击链共用）。
/// 窗口可被用户随时移动/缩放，绝对屏幕坐标不能缓存：每次点击都按窗口 ID
/// 重新读取 CGWindowList bounds，再用归一化偏移量换算成全局点。
enum WindowGeometry {
    /// 目标窗口此刻的全局 bounds（左上原点 point）。
    static func frame(of windowID: CGWindowID) -> CGRect? {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in raw {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  id == windowID,
                  let dict = info[kCGWindowBounds as String] as? [String: NSNumber],
                  let width = dict["Width"]?.doubleValue,
                  let height = dict["Height"]?.doubleValue,
                  width > 0, height > 0
            else { continue }
            return CGRect(
                x: dict["X"]?.doubleValue ?? 0,
                y: dict["Y"]?.doubleValue ?? 0,
                width: width,
                height: height
            )
        }
        return nil
    }

    /// 目标点最上面的 layer-0 窗口（CGWindowList 顺序即前到后）。
    static func topWindow(at point: CGPoint) -> (id: CGWindowID, owner: String)? {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for info in list {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: NSNumber],
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }

            let rect = CGRect(
                x: bounds["X"]?.doubleValue ?? 0,
                y: bounds["Y"]?.doubleValue ?? 0,
                width: bounds["Width"]?.doubleValue ?? 0,
                height: bounds["Height"]?.doubleValue ?? 0
            )
            if rect.contains(point) {
                return (id, info[kCGWindowOwnerName as String] as? String ?? "未知窗口")
            }
        }
        return nil
    }
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
    /// 全量 layer-0 窗口（不限 owner），供手动选择兜底（自动发现失败时用）。
    private(set) var allWindows: [GameWindowCandidate] = []

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

    /// 自动选择的目标候选：手动指定 > 标题命中 > WeChatAppEx 自有窗口。
    var effectiveCandidate: GameWindowCandidate? {
        if let selectedWindowID, let picked = allWindows.first(where: { $0.id == selectedWindowID }) {
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
        let result = Self.enumerate(match: match)
        allWindows = result.all
        candidates = result.matched
    }

    /// 一次枚举同时产出：全量窗口（手动选择用）与 owner 过滤后的候选（自动匹配用）。
    private static func enumerate(match: WindowMatch) -> (all: [GameWindowCandidate], matched: [GameWindowCandidate]) {
        // 用 .optionAll 而不是 .optionOnScreenOnly：窗口被拖到屏幕外时仍要能被发现，
        // 进入流程才能用 AX 把它移回可见区域（P0-6 实测：用户会把窗口拖出屏幕）。
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else { return (all: [], matched: []) }

        let all: [GameWindowCandidate] = raw.compactMap { info in
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
        let matched = all.filter { match.ownerBundleIDs.contains($0.bundleID) }
        return (all, matched)
    }
}
