import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case windowNotFound(CGWindowID)

    var errorDescription: String? {
        switch self {
        case .windowNotFound(let id): "窗口不存在或已关闭（id: \(id)）"
        }
    }
}

/// 窗口级抓帧服务（设计文档 §6 CaptureService）。
/// M0-5 骨架：@MainActor + 最新帧单帧语义，感知（M1）与克隆视图（M0-11）都取 latestFrame；
/// 吞吐不足时再拆帧分发 actor 与后台转换。
@MainActor
@Observable
final class CaptureService {
    private(set) var isCapturing = false
    private(set) var latestFrame: CapturedFrame?
    private(set) var lastError: String?

    private var stream: SCStream?
    private var output: StreamOutput?
    private var currentWindowID: CGWindowID?
    private var pointSize: CGSize = .zero
    private var lastLoggedFrameSize: String?
    /// 最近一次检测到的内容区（归一化）。
    private var contentRect: CGRect = CapturedFrame.fullFrame
    private var frameCounter = 0
    private let outputQueue = DispatchQueue(label: "wgai.capture.output")

    /// 窗口尺寸变化时更新（用户缩放游戏窗口后调用）。
    func updateWindowSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        pointSize = size
    }

    /// 启动或切换到目标窗口；同窗口重复调用为 no-op。
    func startOrSwitch(to windowID: CGWindowID) async {
        if isCapturing, currentWindowID == windowID { return }
        await teardown()
        do {
            try await start(windowID: windowID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() async {
        await teardown()
    }

    private func teardown() async {
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        output = nil
        currentWindowID = nil
        pointSize = .zero
        latestFrame = nil
        isCapturing = false
    }

    private func start(windowID: CGWindowID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound(windowID)
        }

        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15) // 15fps，观察器足够
        config.queueDepth = 3
        config.showsCursor = false
        // 不设 width/height：按小程序原生画布输出（实测 461×303 的窗口会拿到
        // 1920×1080 帧，游戏只占左上角、其余是黑边）。原生画布分辨率更高，
        // 靠 detectContentRect 裁到内容区即可，裁完的帧与窗口一一对应。

        pointSize = window.frame.size
        currentWindowID = windowID
        latestFrame = nil
        lastError = nil

        let output = StreamOutput(
            onFrame: { [weak self] pixelBuffer, timestamp in
                Task { @MainActor in
                    self?.ingest(pixelBuffer: pixelBuffer, timestamp: timestamp)
                }
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    self?.lastError = message
                    self?.isCapturing = false
                    self?.stream = nil
                }
            }
        )
        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: config,
            delegate: output
        )
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)

        self.output = output
        self.stream = stream
        try await stream.startCapture()
        isCapturing = true
    }

    private func ingest(pixelBuffer: CVPixelBuffer, timestamp: Double) {
        guard pointSize.width > 0 else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // 内容区每 8 帧（~0.5s）重算一次：窗口缩放会改变黑边范围。
        frameCounter += 1
        if frameCounter % 8 == 1 || contentRect == CapturedFrame.fullFrame {
            contentRect = Self.detectContentRect(pixelBuffer)
        }

        let contentWidth = CGFloat(width) * contentRect.width
        let scale = contentWidth / pointSize.width
        let sizeKey = "\(width)x\(height) content=\(contentRect)"
        if lastLoggedFrameSize != sizeKey {
            lastLoggedFrameSize = sizeKey
            NSLog("TTJ capture frame %@ scale=%.2f point=%@", sizeKey, scale, "\(pointSize)")
        }
        // SCStream 的 PTS 与主机时钟同源；换算出捕获时刻，端到端延迟从这里起算。
        // PTS 不可比时（负值/过旧）退回入队时刻，至少不会把延迟算成负数。
        let now = CACurrentMediaTime()
        let age = now - timestamp
        let capturedAt = (age >= 0 && age < 2) ? timestamp : now
        latestFrame = CapturedFrame(
            pixelBuffer: pixelBuffer,
            scale: scale,
            timestamp: timestamp,
            contentRect: contentRect,
            capturedAt: capturedAt
        )
    }

    /// 检测帧内非黑内容区（小游戏原生画布四周可能有黑边）。
    /// 做法：降采样到 240px 宽的小图，找非黑像素的包围盒。
    nonisolated static func detectContentRect(_ pixelBuffer: CVPixelBuffer) -> CGRect {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 8, height > 8 else { return CapturedFrame.fullFrame }

        let probeWidth = 240
        let probeHeight = max(8, Int((Double(height) / Double(width)) * Double(probeWidth)))
        var pixels = [UInt8](repeating: 0, count: probeWidth * probeHeight * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: probeWidth,
            height: probeHeight,
            bitsPerComponent: 8,
            bytesPerRow: probeWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CapturedFrame.fullFrame }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scaleX = Double(probeWidth) / Double(width)
        let scaleY = Double(probeHeight) / Double(height)
        let scaled = image.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
        )
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        guard let probe = ciContext.createCGImage(scaled, from: scaled.extent) else {
            return CapturedFrame.fullFrame
        }
        // CGContext 原点在左下，CIImage 在左上：翻转后坐标才一致。
        context.translateBy(x: 0, y: CGFloat(probeHeight))
        context.scaleBy(x: 1, y: -1)
        context.draw(probe, in: CGRect(x: 0, y: 0, width: probeWidth, height: probeHeight))

        // 行/列剖面：某一行（列）里"亮"像素够多才算内容行（列），
        // 这样游戏自身暗边（棋盘深色背景）不会被误裁掉。
        func isLit(_ index: Int) -> Bool {
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            let alpha = pixels[index + 3]
            return alpha > 8 && max(red, max(green, blue)) > 6
        }

        var minY = -1
        var maxY = -1
        let rowThreshold = max(4, probeWidth / 8)
        for y in 0..<probeHeight {
            var count = 0
            for x in 0..<probeWidth where isLit((y * probeWidth + x) * 4) {
                count += 1
                if count >= rowThreshold { break }
            }
            if count >= rowThreshold {
                if minY < 0 { minY = y }
                maxY = y
            }
        }

        var minX = -1
        var maxX = -1
        let columnThreshold = max(4, probeHeight / 8)
        for x in 0..<probeWidth {
            var count = 0
            for y in 0..<probeHeight where isLit((y * probeWidth + x) * 4) {
                count += 1
                if count >= columnThreshold { break }
            }
            if count >= columnThreshold {
                if minX < 0 { minX = x }
                maxX = x
            }
        }

        guard minX >= 0, maxX >= minX, minY >= 0, maxY >= minY else {
            return CapturedFrame.fullFrame
        }

        let rect = CGRect(
            x: Double(minX) / Double(probeWidth),
            y: Double(minY) / Double(probeHeight),
            width: Double(maxX - minX + 1) / Double(probeWidth),
            height: Double(maxY - minY + 1) / Double(probeHeight)
        )
        // 明显不合理（内容只占一点点 / 超出整帧）就退回整帧。
        let area = rect.width * rect.height
        guard area > 0.05, rect.maxX <= 1.001, rect.maxY <= 1.001 else { return CapturedFrame.fullFrame }
        return rect
    }
}

/// SCStream 输出桥：回调发生在捕获队列，逐帧上抛；错误经 onError 回主线程。
/// nonisolated：默认 MainActor 隔离会错误推断本类型（回调在后台队列）。
nonisolated private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let onFrame: @Sendable (_ pixelBuffer: CVPixelBuffer, _ timestamp: Double) -> Void
    let onError: @Sendable (_ message: String) -> Void

    init(
        onFrame: @escaping @Sendable (_ pixelBuffer: CVPixelBuffer, _ timestamp: Double) -> Void,
        onError: @escaping @Sendable (_ message: String) -> Void
    ) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        onFrame(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onError(error.localizedDescription)
    }
}
