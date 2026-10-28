import CoreImage
import CoreVideo
import Foundation
import Vision

/// 棋盘四角自动检测（M1-2）：Vision 矩形检测 + 宽高比/面积过滤。
/// 输入是抓帧内容区（与 OCR/校准同一坐标系），输出归一化四角。
enum BoardDetector {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 检测最可能的棋盘四边形；失败返回 nil，由调用方回退到校准锚点或手动点选。
    static func detect(
        in frame: CapturedFrame,
        rows: Int,
        cols: Int
    ) -> BoardQuad? {
        guard rows > 0, cols > 0 else { return nil }

        var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let extent = image.extent
        guard extent.width > 16, extent.height > 16 else { return nil }

        let content = frame.contentRect
        if content != CapturedFrame.fullFrame {
            image = image.cropped(to: CGRect(
                x: extent.minX + content.minX * extent.width,
                y: extent.minY + content.minY * extent.height,
                width: content.width * extent.width,
                height: content.height * extent.height
            ))
        }

        let imageAspect = image.extent.width / image.extent.height
        guard imageAspect > 0, imageAspect.isFinite else { return nil }

        // 小窗口先放大，和大窗口保持相近的检测条件。
        let scale: CGFloat = image.extent.width < 1200 ? 2 : 1
        let prepared = scale > 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        guard let cgImage = ciContext.createCGImage(prepared, from: prepared.extent) else {
            return nil
        }

        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.3
        // Vision 的矩形比例口径随系统版本/图像比例有差异，先放宽，
        // 再用物理宽高比在下面精筛。
        request.minimumAspectRatio = 0.5
        request.maximumAspectRatio = 6.0
        request.minimumSize = 0.15
        request.quadratureTolerance = 30
        request.maximumObservations = 8

        do {
            try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
        } catch {
            return nil
        }

        let targetAspect = CGFloat(cols) / CGFloat(rows)
        let candidates = (request.results ?? []).compactMap { observation -> (BoardQuad, CGFloat)? in
            // Vision 归一化坐标原点在左下；转成左上原点。
            let corners = [
                observation.topLeft,
                observation.topRight,
                observation.bottomRight,
                observation.bottomLeft,
            ].map { CGPoint(x: $0.x, y: 1 - $0.y) }

            guard let quad = BoardQuad(corners: corners), quad.isValid else { return nil }
            guard quad.area > 0.08 else { return nil }

            let aspect = quad.physicalAspect(imageAspect: imageAspect)
            let aspectError = abs(aspect - targetAspect) / targetAspect
            guard aspectError < 0.35 else { return nil }

            let areaScore: CGFloat = min(1, quad.area / 0.35)
            let aspectScore: CGFloat = 1 - aspectError
            let shapeScore: CGFloat = 0.6 + 0.4 * areaScore
            let confidence: CGFloat = CGFloat(observation.confidence)
            let score: CGFloat = confidence * aspectScore * shapeScore
            return (quad, score)
        }

        return candidates.max { $0.1 < $1.1 }?.0
    }
}
