import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// 一帧捕获结果。
struct CapturedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// pixel / point 换算比（设计文档 §9.2 坐标换算）。
    let scale: CGFloat
    let timestamp: Double
}

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
    private let outputQueue = DispatchQueue(label: "wgai.capture.output")

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
        // 不设 width/height：按窗口原生像素分辨率输出，scale 由帧尺寸换算

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
        let scale = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / pointSize.width
        latestFrame = CapturedFrame(pixelBuffer: pixelBuffer, scale: scale, timestamp: timestamp)
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
