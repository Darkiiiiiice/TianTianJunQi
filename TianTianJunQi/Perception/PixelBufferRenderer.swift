import CoreGraphics
import CoreImage
import CoreVideo

/// M1-9：把 CIImage 直接渲染到 CVPixelBuffer，供 Core ML 图像输入使用。
///
/// 之前走 `CGImage` → `MLFeatureValue(cgImage:constraint:)`，每格都要再做一次
/// 颜色空间/尺寸转换；在实时路径上（60 格 × 15fps）开销远高于推理本身。
/// 直接给模型 `MLFeatureValue(pixelBuffer:)` 可以绕开这段转换。
nonisolated enum PixelBufferRenderer {
    static func make(
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA
    ) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// 按 buffer 尺寸渲染；调用方负责保证 image 已经裁/缩放到目标范围。
    @discardableResult
    static func render(
        _ image: CIImage,
        to buffer: CVPixelBuffer,
        context: CIContext,
        colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    ) -> Bool {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return false }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return false }
        // CIContext.render 要求 bounds 在 image.extent 内；先平移到原点再缩放。
        let normalized = image.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        ).transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / extent.width,
                y: CGFloat(height) / extent.height
            )
        )
        context.render(normalized, to: buffer, bounds: bounds, colorSpace: colorSpace)
        return true
    }
}
