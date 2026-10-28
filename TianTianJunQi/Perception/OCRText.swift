import CoreGraphics
import Foundation

/// 一条 OCR 结果：文本 + 归一化包围盒。
struct OCRText: Sendable {
    let text: String
    /// 归一化 0..1、左上原点，相对整窗（含标题栏）。
    let rect: CGRect
    let confidence: Float
}
