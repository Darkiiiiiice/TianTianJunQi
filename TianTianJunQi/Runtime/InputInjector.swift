import CoreGraphics
import Foundation

enum InputError: LocalizedError {
    case eventCreateFailed

    var errorDescription: String? {
        "CGEvent 创建失败（请检查辅助功能权限）"
    }
}

/// 鼠标注入：CGEvent 全局 HID 事件 + 归一化坐标换算（设计文档 §9.2）。
/// 注入坐标用全局屏幕坐标（point，左上原点），与 CGWindowList bounds 同一坐标系。
actor InputInjector {
    /// 点击窗口内归一化坐标（左上原点 0..1）。
    /// - Parameters:
    ///   - point: 归一化点击点
    ///   - windowBounds: 目标窗口的 CGWindowList 全局 bounds（point）
    func click(normalized point: CGPoint, in windowBounds: CGRect) async throws {
        let global = CGPoint(
            x: windowBounds.minX + point.x * windowBounds.width,
            y: windowBounds.minY + point.y * windowBounds.height
        )
        // 轻微随机抖动与按下间隔，避免机械固定节奏（§9.8；是拟人化而非反检测手段）
        let target = CGPoint(
            x: global.x + Double.random(in: -2...2),
            y: global.y + Double.random(in: -2...2)
        )
        guard
            let down = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: target, mouseButton: .left
            ),
            let up = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: target, mouseButton: .left
            )
        else { throw InputError.eventCreateFailed }

        down.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(Int.random(in: 30...80)))
        up.post(tap: .cghidEventTap)
    }
}
