import CoreGraphics
import CoreML
import Foundation

enum BoardPieceClassifierError: LocalizedError {
    case modelNotFound(String)
    case missingImageInput(String)
    case missingOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            "找不到 Core ML 模型 \(name).mlmodelc（确认 Models/BoardClassifier/v2 已加入 app target）"
        case .missingImageInput(let name):
            "模型 \(name) 没有图像输入"
        case .missingOutput(let name):
            "模型 \(name) 缺少 classLabel / classLabel_probs 输出"
        }
    }
}

/// M1-3 三分类器 → M1-4 逐格观察。
///
/// state 先判空/暗/明；只有 revealed 才继续跑 color 与 piece，省掉大部分推理。
/// 任一环节置信度不足或标签不可用时降级为 unknown，交给 BoardStabilizer 投票。
struct BoardPieceClassifier: @unchecked Sendable {
    struct Config: Equatable, Sendable {
        var cellSize = 128
        /// 必须与 `BoardSnapshotExporter` 的训练口径一致。
        var inset: CGFloat = 0.04
        /// 低于该置信度的模型输出视为不可用（与 BoardStabilizerConfig 默认值一致）。
        var minConfidence = 0.55
        var stateModel = "state"
        var colorModel = "color"
        var pieceModel = "piece"
    }

    private struct Prediction {
        let label: String
        let confidence: Double
    }

    private struct LoadedModel {
        let name: String
        let model: MLModel
        let inputName: String
        let imageConstraint: MLImageConstraint

        init(name: String, bundle: Bundle) throws {
            guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
                throw BoardPieceClassifierError.modelNotFound(name)
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndGPU
            let model = try MLModel(contentsOf: url, configuration: configuration)
            guard let input = model.modelDescription.inputDescriptionsByName.first(where: {
                $0.value.type == .image
            }), let constraint = input.value.imageConstraint else {
                throw BoardPieceClassifierError.missingImageInput(name)
            }
            self.name = name
            self.model = model
            self.inputName = input.key
            self.imageConstraint = constraint
        }

        func predict(_ image: CGImage) throws -> Prediction {
            let value = try MLFeatureValue(
                cgImage: image,
                constraint: imageConstraint,
                options: nil
            )
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: value])
            let result = try model.prediction(from: provider)
            guard let label = result.featureValue(for: "classLabel")?.stringValue else {
                throw BoardPieceClassifierError.missingOutput(name)
            }
            var probabilities: [String: Double] = [:]
            result.featureValue(for: "classLabel_probs")?.dictionaryValue.forEach { key, number in
                if let key = key as? String {
                    probabilities[key] = number.doubleValue
                }
            }
            return Prediction(
                label: label,
                confidence: probabilities[label] ?? probabilities.values.max() ?? 0
            )
        }
    }

    let config: Config
    private let state: LoadedModel
    private let color: LoadedModel
    private let piece: LoadedModel

    init(config: Config = Config(), bundle: Bundle = .main) throws {
        let state = try LoadedModel(name: config.stateModel, bundle: bundle)
        let color = try LoadedModel(name: config.colorModel, bundle: bundle)
        let piece = try LoadedModel(name: config.pieceModel, bundle: bundle)
        self.config = config
        self.state = state
        self.color = color
        self.piece = piece
    }

    /// 逐格推理，输出与 `grid` 行优先一致的棋盘观察。
    func classify(frame: CapturedFrame, grid: BoardGrid) throws -> BoardObservation {
        let images = try BoardSnapshotExporter.cellImages(
            from: frame,
            grid: grid,
            cellSize: config.cellSize,
            inset: config.inset
        )
        var cells: [CellObservation] = []
        cells.reserveCapacity(images.count)
        for image in images {
            cells.append(classify(image))
        }
        guard let observation = BoardObservation(
            rows: grid.rows,
            cols: grid.cols,
            cells: cells
        ) else {
            preconditionFailure("格子数量与棋盘尺寸不一致")
        }
        return observation
    }

    // MARK: - 单格分类

    private func classify(_ image: CGImage) -> CellObservation {
        guard let statePrediction = try? state.predict(image) else {
            return .unknown()
        }
        guard statePrediction.label == CellState.revealed.rawValue else {
            return Self.observation(
                stateLabel: statePrediction.label,
                stateConfidence: statePrediction.confidence,
                minConfidence: config.minConfidence
            )
        }

        // 只有明子才继续判颜色与军衔。
        let colorPrediction = try? color.predict(image)
        let piecePrediction = try? piece.predict(image)
        return Self.observation(
            stateLabel: statePrediction.label,
            stateConfidence: statePrediction.confidence,
            colorLabel: colorPrediction?.label,
            colorConfidence: colorPrediction?.confidence ?? 0,
            pieceLabel: piecePrediction?.label,
            pieceConfidence: piecePrediction?.confidence ?? 0,
            minConfidence: config.minConfidence
        )
    }

    /// 三模型输出 → CellObservation 的纯映射（置信度阈值、标签校验、中文名映射）。
    static func observation(
        stateLabel: String,
        stateConfidence: Double,
        colorLabel: String? = nil,
        colorConfidence: Double = 0,
        pieceLabel: String? = nil,
        pieceConfidence: Double = 0,
        minConfidence: Double
    ) -> CellObservation {
        guard stateConfidence >= minConfidence,
              let state = CellState(rawValue: stateLabel)
        else {
            return .unknown(confidence: stateConfidence)
        }

        switch state {
        case .empty:
            return .empty(confidence: stateConfidence)
        case .hidden:
            return .hidden(confidence: stateConfidence)
        case .unknown:
            return .unknown(confidence: stateConfidence)
        case .revealed:
            let confidence = min(stateConfidence, colorConfidence, pieceConfidence)
            guard colorConfidence >= minConfidence,
                  pieceConfidence >= minConfidence,
                  let colorLabel,
                  let color = PieceColor(rawValue: colorLabel),
                  let pieceLabel,
                  let name = PieceCatalog.name(forClassifierID: pieceLabel)
            else {
                return .unknown(confidence: confidence)
            }
            return .revealed(color, name, confidence: confidence)
        }
    }
}
