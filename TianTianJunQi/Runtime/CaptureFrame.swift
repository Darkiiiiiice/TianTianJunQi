import CoreGraphics
import CoreVideo
import Foundation

/// 一帧捕获结果。
struct CapturedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// pixel / point 换算比（设计文档 §9.2 坐标换算），按内容区计算。
    let scale: CGFloat
    let timestamp: Double
    /// 游戏内容在帧内的归一化范围（0..1，左上原点）。
    /// SCStream 默认按小游戏原生画布输出（实测 461×303 的窗口拿到 1920×1080 帧，
    /// 游戏只占左上角，其余是黑边）。裁到内容区后，帧与窗口一一对应，
    /// OCR 归一化坐标才能直接映射到窗口坐标（否则点击会整体偏移）。
    let contentRect: CGRect
    /// 捕获时间（主机时钟，`CACurrentMediaTime()` 秒），端到端延迟的起点。
    /// 无法从 SCStream PTS 换算时退回入队时间。
    let capturedAt: Double

    init(
        pixelBuffer: CVPixelBuffer,
        scale: CGFloat,
        timestamp: Double,
        contentRect: CGRect,
        capturedAt: Double? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.scale = scale
        self.timestamp = timestamp
        self.contentRect = contentRect
        self.capturedAt = capturedAt ?? timestamp
    }

    /// 整帧（内容未裁剪）的归一化范围。
    static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
}
