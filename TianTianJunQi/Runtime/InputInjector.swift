import AppKit
import CoreGraphics
import Foundation

enum InputError: LocalizedError {
    case eventCreateFailed
    case userActive
    case targetOffScreen(CGPoint)
    case windowNotRaised(String)
    case accessibilityUnavailable

    var errorDescription: String? {
        switch self {
        case .eventCreateFailed:
            "CGEvent 创建失败（请检查辅助功能权限）"
        case .userActive:
            "检测到你正在操作鼠标/键盘，已暂停；请停止操作后重试"
        case .targetOffScreen(let point):
            "点击目标在屏幕外 \(Int(point.x)), \(Int(point.y))；请把游戏窗口移回屏幕内"
        case .windowNotRaised(let owner):
            "游戏窗口未能在最前（当前最前：\(owner)），已暂停；请手动点一下游戏窗口后重试"
        case .accessibilityUnavailable:
            "辅助功能权限未生效，请重新授权并重启客户端"
        }
    }
}

/// 点击投递方式。
enum ClickDelivery: String, Sendable {
    /// 进程定向事件：不移动系统指针。实测微信小游戏会忽略，仅保留为实验开关。
    case process
    /// 全局 HID 点击：会短暂移动系统指针，随后立刻还原。
    case global
}

/// 一次点击的可观测结果，写入步骤日志。
struct ClickReport: Sendable {
    let point: CGPoint
    let windowBounds: CGRect
    let delivery: ClickDelivery
    /// 指针是否已还原到点击前位置。
    let cursorRestored: Bool
}

/// 鼠标注入（设计文档 §9.2）。
/// 注入坐标用全局屏幕坐标（point，左上原点），与 CGWindowList bounds 同一坐标系。
///
/// 实测结论（2026-10-23）：`CGEvent.postToPid` 不移动系统指针，但微信小游戏窗口
/// （主进程与 WeChatAppEx 渲染进程）均忽略定向事件。公开 API 下唯一可靠的注入是
/// 全局 HID 点击；因此默认采用“保存指针 → 点击 → 立即还原”，把指针占用压到 ~150ms。
actor InputInjector {
    /// 点击后还原系统指针。默认开启。
    var preserveCursor = true
    /// 点击前等待用户停止操作鼠标，避免和用户抢指针。默认开启。
    var respectUserInput = true
    /// 尝试进程定向点击（微信小游戏不支持，默认关闭）。
    var useProcessDelivery = false

    /// 点击窗口内归一化坐标（左上原点 0..1）。
    /// - Parameters:
    ///   - point: 归一化点击点
    ///   - windowBounds: 目标窗口的 CGWindowList 全局 bounds（point）
    ///   - windowID: 目标窗口 ID（用于事件字段）
    ///   - pid: 目标进程 PID（仅 process 投递使用）
    func click(
        normalized point: CGPoint,
        in windowBounds: CGRect,
        windowID: CGWindowID,
        pid: pid_t
    ) async throws -> ClickReport {
        let global = CGPoint(
            x: windowBounds.minX + point.x * windowBounds.width,
            y: windowBounds.minY + point.y * windowBounds.height
        )

        if respectUserInput {
            try await waitForUserIdle()
        }
        guard Self.isOnScreen(global) else {
            throw InputError.targetOffScreen(global)
        }

        // 轻微随机抖动与按下间隔，避免机械固定节奏（§9.8；是拟人化而非反检测手段）
        let target = CGPoint(
            x: global.x + Double.random(in: -2...2),
            y: global.y + Double.random(in: -2...2)
        )

        let delivery: ClickDelivery = useProcessDelivery ? .process : .global
        let source = CGEventSource(stateID: .hidSystemState)
        let before = CGEvent(source: nil)?.location ?? .zero

        func makeEvent(_ type: CGEventType) -> CGEvent? {
            let event = CGEvent(
                mouseEventSource: source, mouseType: type,
                mouseCursorPosition: target, mouseButton: .left
            )
            event?.setIntegerValueField(
                .mouseEventWindowUnderMousePointer, value: Int64(windowID)
            )
            event?.setIntegerValueField(
                .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID)
            )
            return event
        }

        guard
            let move = makeEvent(.mouseMoved),
            let down = makeEvent(.leftMouseDown),
            let up = makeEvent(.leftMouseUp)
        else { throw InputError.eventCreateFailed }

        func post(_ event: CGEvent) {
            if delivery == .process {
                event.postToPid(pid)
            } else {
                event.post(tap: .cghidEventTap)
            }
        }

        post(move)
        try await Task.sleep(for: .milliseconds(Int.random(in: 20...40)))
        post(down)
        try await Task.sleep(for: .milliseconds(Int.random(in: 45...80)))
        post(up)

        var restored = false
        if preserveCursor, delivery == .global {
            // 给游戏一点时间处理 up 事件，再还原指针。
            try await Task.sleep(for: .milliseconds(35))
            let after = CGEvent(source: nil)?.location ?? .zero
            // 如果用户在这 150ms 内自己移动了指针，就不要覆盖用户的新位置。
            if hypot(after.x - target.x, after.y - target.y) < 6 {
                CGWarpMouseCursorPosition(before)
                restored = true
            }
        }

        return ClickReport(
            point: global, windowBounds: windowBounds,
            delivery: delivery, cursorRestored: restored
        )
    }

    /// 等用户键鼠空闲；最多等 1.2s，仍在使用则抛错让上层暂停。
    /// 只检查鼠标移动/点击不够：滚动、拖拽、键盘输入同样会打断用户。
    private func waitForUserIdle() async throws {
        let watched: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseDragged,
            .rightMouseDown, .rightMouseDragged, .otherMouseDown,
            .scrollWheel, .keyDown,
        ]
        for _ in 0..<6 {
            let idle = watched
                .map {
                    CGEventSource.secondsSinceLastEventType(
                        .combinedSessionState, eventType: $0
                    )
                }
                .min() ?? 0
            if idle > 0.7 { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw InputError.userActive
    }

    /// 目标点是否落在任意一块活动屏幕内。
    static func isOnScreen(_ point: CGPoint) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return false
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return false
        }
        return displays.prefix(Int(count)).contains {
            CGDisplayBounds($0).contains(point)
        }
    }
}
