import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

enum ScreenClassifierError: LocalizedError {
    case modelNotFound(String)
    case missingImageInput(String)
    case missingOutput(String)
    case imageRenderFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            "找不到 Core ML 屏幕分类器 \(name).mlmodelc（确认 Models/ScreenClassifier 已加入 app target）"
        case .missingImageInput(let name):
            "屏幕分类器 \(name) 没有图像输入"
        case .missingOutput(let name):
            "屏幕分类器 \(name) 缺少 classLabel / classLabel_probs 输出"
        case .imageRenderFailed:
            "屏幕分类器输入图像渲染失败"
        }
    }
}

/// 一次屏幕分类输出。
struct ScreenPrediction: Sendable {
    let label: String
    let confidence: Double
    let probabilities: [String: Double]
}

/// M1-7：七分类屏幕分类器。
///
/// 输入是窗口内容区（含小游戏标题栏）缩放后的 RGB 图像；模型由
/// `wgai screen-train` 训练、`wgai screen-coreml` 导出，类别顺序固定为
/// `main/modeLobby/matching/board/result/popup/unknown`。
///
/// 模型在 app 启动时通过 `warmUp()` 预热一次，避免第一次状态切换时才编译/分配。
/// M1-9：输入走 CVPixelBuffer 直通，避免 CGImage → MLFeatureValue 的逐帧转换。
nonisolated struct ScreenClassifier: @unchecked Sendable {
    static let defaultModelName = "screen"
    static let defaultMinConfidence = 0.60

    struct Config: Equatable, Sendable {
        var modelName = ScreenClassifier.defaultModelName
        var minConfidence = ScreenClassifier.defaultMinConfidence
        var computeUnits: MLComputeUnits = .cpuAndGPU
    }

    let config: Config
    private let model: MLModel
    private let inputName: String
    private let imageConstraint: MLImageConstraint

    nonisolated private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(config: Config = Config(), bundle: Bundle = .main) throws {
        let url = try Self.locateModel(name: config.modelName, bundle: bundle)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = config.computeUnits
        let model = try MLModel(contentsOf: url, configuration: configuration)
        guard let input = model.modelDescription.inputDescriptionsByName.first(where: {
            $0.value.type == .image
        }), let constraint = input.value.imageConstraint else {
            throw ScreenClassifierError.missingImageInput(config.modelName)
        }
        self.config = config
        self.model = model
        self.inputName = input.key
        self.imageConstraint = constraint
    }

    /// 用一张纯色图跑一次完整前向，触发 Core ML 的首次图计划/权重加载。
    /// 返回预热耗时（毫秒）。
    func warmUp() throws -> Double {
        let width = imageConstraint.pixelsWide
        let height = imageConstraint.pixelsHigh
        guard width > 0, height > 0 else {
            throw ScreenClassifierError.imageRenderFailed
        }
        guard let buffer = PixelBufferRenderer.make(
            width: width,
            height: height,
            pixelFormat: imageConstraint.pixelFormatType
        ) else {
            throw ScreenClassifierError.imageRenderFailed
        }
        let color = CIImage(
            color: CIColor(red: 0.5, green: 0.5, blue: 0.5)
        ).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        guard PixelBufferRenderer.render(color, to: buffer, context: Self.ciContext) else {
            throw ScreenClassifierError.imageRenderFailed
        }
        let started = Date()
        _ = try predict(buffer)
        return Date().timeIntervalSince(started) * 1000
    }

    /// 从抓帧内容区分类；坐标与 OCR/点击共用同一归一化内容区。
    func predict(pixelBuffer: CVPixelBuffer, contentRect: CGRect) throws -> ScreenPrediction {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            throw ScreenClassifierError.imageRenderFailed
        }
        let crop = contentRect == CapturedFrame.fullFrame
            ? extent
            : CGRect(
                x: extent.minX + contentRect.minX * extent.width,
                y: extent.minY + contentRect.minY * extent.height,
                width: contentRect.width * extent.width,
                height: contentRect.height * extent.height
            )
        let cropped = image.cropped(to: crop)

        let width = imageConstraint.pixelsWide
        let height = imageConstraint.pixelsHigh
        guard width > 0, height > 0 else {
            throw ScreenClassifierError.imageRenderFailed
        }
        guard let buffer = PixelBufferRenderer.make(
            width: width,
            height: height,
            pixelFormat: imageConstraint.pixelFormatType
        ) else {
            throw ScreenClassifierError.imageRenderFailed
        }
        guard PixelBufferRenderer.render(cropped, to: buffer, context: Self.ciContext) else {
            throw ScreenClassifierError.imageRenderFailed
        }
        return try predict(buffer)
    }

    // MARK: - Core ML

    private func predict(_ buffer: CVPixelBuffer) throws -> ScreenPrediction {
        let value = MLFeatureValue(pixelBuffer: buffer)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: value])
        let result = try model.prediction(from: provider)
        guard let label = result.featureValue(for: "classLabel")?.stringValue else {
            throw ScreenClassifierError.missingOutput(config.modelName)
        }
        var probabilities: [String: Double] = [:]
        result.featureValue(for: "classLabel_probs")?.dictionaryValue.forEach { key, number in
            if let key = key as? String {
                probabilities[key] = number.doubleValue
            }
        }
        return ScreenPrediction(
            label: label,
            confidence: probabilities[label] ?? probabilities.values.max() ?? 0,
            probabilities: probabilities
        )
    }

    /// Xcode 通常把 .mlpackage 编译成 bundle 根目录的 .mlmodelc；
    /// 同时兼容未编译包（手动放入 Resources 的场景）。
    private static func locateModel(name: String, bundle: Bundle) throws -> URL {
        if let url = bundle.url(forResource: name, withExtension: "mlmodelc") {
            return url
        }
        if let url = bundle.url(
            forResource: name,
            withExtension: "mlmodelc",
            subdirectory: "Models/ScreenClassifier/v1"
        ) {
            return url
        }
        if let url = bundle.url(forResource: name, withExtension: "mlpackage") {
            return try MLModel.compileModel(at: url)
        }
        if let url = bundle.url(
            forResource: name,
            withExtension: "mlpackage",
            subdirectory: "Models/ScreenClassifier/v1"
        ) {
            return try MLModel.compileModel(at: url)
        }
        throw ScreenClassifierError.modelNotFound(name)
    }
}
