import Foundation
import MLX
import MLXNN

// MARK: - 模型描述文件

/// `model.json`：网络结构（`shared/schema/model.schema.json`）。
/// Python 训练端导出、MLX Swift 按同一份配置重建（设计文档 §8.6）。
struct ModelArchitecture: Codable, Equatable, Sendable {
    struct Input: Codable, Equatable, Sendable {
        var rows: Int
        var cols: Int
        var channels: Int
    }

    struct Heads: Codable, Equatable, Sendable {
        /// "cells"：逐格动作 logits，数量 = rows × cols。
        var policy: String
        /// 价值头宽度（固定 1）。
        var value: Int
    }

    var schema: Int
    var architecture: String
    var input: Input
    /// MLP 主干隐藏层宽度序列。
    var trunk: [Int]
    var heads: Heads

    /// 输入特征数：rows × cols × channels。
    var featureCount: Int { input.rows * input.cols * input.channels }
    /// 策略输出数：rows × cols。
    var policyCount: Int { input.rows * input.cols }
}

/// `manifest.json`：模型来源、指标、版本追溯（`shared/schema/manifest.schema.json`）。
struct ModelManifest: Codable, Equatable, Sendable {
    var modelVersion: Int
    var modelFile: String
    var architectureFile: String
    var rulesVersion: String
    var perceptionVersion: String
    var gameVersion: String?
    /// `sha256:<64 hex>`。
    var datasetHash: String
    var metrics: [String: Double]
    /// ISO 8601 日期时间字符串。
    var createdAt: String
}

enum PolicyError: LocalizedError {
    case missingFile(URL)
    case smokeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let url):
            return "模型文件缺失：\(url.lastPathComponent)"
        case .smokeFailed(let reason):
            return "推理 smoke test 失败：\(reason)"
        }
    }
}

// MARK: - 网络

/// 策略价值网络（M0-9 占位）：扁平特征 → MLP 主干（ReLU）→ policy（cells logits）+ value（标量）。
///
/// 权重键名（`model.safetensors`）：`trunk.<i>.weight/bias`、`policy.weight/bias`、`value.weight/bias`。
/// M3 的 Python MLX 训练端按同名导出，推理一致性容差 1e-4（设计文档 §8.6）。
nonisolated final class PolicyValueNet: Module {
    @ModuleInfo var trunk: [Linear]
    @ModuleInfo var policy: Linear
    @ModuleInfo var value: Linear

    init(_ arch: ModelArchitecture) {
        let dims = [arch.featureCount] + arch.trunk
        var layers: [Linear] = []
        for i in 0..<(dims.count - 1) {
            layers.append(Linear(dims[i], dims[i + 1]))
        }
        self.trunk = layers
        self.policy = Linear(dims[dims.count - 1], arch.policyCount)
        self.value = Linear(dims[dims.count - 1], 1)
    }

    func forward(_ x: MLXArray) -> (policy: MLXArray, value: MLXArray) {
        var h = x
        for layer in trunk {
            h = relu(layer(h))
        }
        return (policy(h), value(h))
    }
}

// MARK: - PolicyKit

/// 策略运行时（设计文档 §6 PolicyRuntime）：加载 `model.json` + `model.safetensors`，进程内 MLX 推理；
/// 运行时不需要 Python。热替换在 M3-5 接入（冻结快照 + 评测通过后切换）。
struct PolicyKit {
    let directory: URL
    let architecture: ModelArchitecture
    let manifest: ModelManifest?

    private let net: PolicyValueNet

    /// 从模型目录加载：`model.json` + `model.safetensors`（`manifest.json` 可选）。
    static func load(directory: URL) throws -> PolicyKit {
        let archURL = directory.appendingPathComponent("model.json")
        let weightsURL = directory.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: archURL.path) else {
            throw PolicyError.missingFile(archURL)
        }
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw PolicyError.missingFile(weightsURL)
        }

        let arch = try JSONDecoder().decode(ModelArchitecture.self, from: Data(contentsOf: archURL))
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = FileManager.default.fileExists(atPath: manifestURL.path)
            ? try? JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: manifestURL))
            : nil

        let net = PolicyValueNet(arch)
        let arrays = try loadArrays(url: weightsURL)
        _ = net.update(parameters: .unflattened(arrays))
        return PolicyKit(directory: directory, architecture: arch, manifest: manifest, net: net)
    }

    /// 进程内前向：输入 `[1, rows×cols×channels]`，输出 cells logits 与价值。
    func forward(features: MLXArray) -> (logits: [Float], value: [Float]) {
        let out = net.forward(features)
        eval(out.policy, out.value)
        return (out.policy.asArray(Float.self), out.value.asArray(Float.self))
    }

    /// 保存权重到 `model.safetensors`（与 `flatten` 参数键名一致）。
    static func saveWeights(_ net: PolicyValueNet, to url: URL) throws {
        let flat = net.parameters().flattened()
        try save(arrays: [String: MLXArray](uniqueKeysWithValues: flat), url: url)
    }

    // MARK: M0-9 推理 smoke test

    struct SmokeReport: Sendable {
        var modelDirectory: String
        var policyCount: Int
        var valueCount: Int
        var latencyMS: Double
        var reloadConsistent: Bool
    }

    /// M0-9 smoke test：随机初始化 dummy 策略 → 写 `model.safetensors` + `model.json` + `manifest.json`
    /// → 重新加载 → 固定输入进程内前向，校验形状/有限性/加载前后一致。
    @discardableResult
    static func smokeTest(storage: StorageKit = StorageKit()) throws -> SmokeReport {
        let arch = ModelArchitecture(
            schema: 1,
            architecture: "mlp_policy_value",
            input: .init(rows: 5, cols: 12, channels: 4),
            trunk: [128, 128],
            heads: .init(policy: "cells", value: 1)
        )

        let dir = storage.modelsURL.appendingPathComponent("dummy-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. 随机初始化并落盘
        let net = PolicyValueNet(arch)
        try saveWeights(net, to: dir.appendingPathComponent("model.safetensors"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(arch).write(to: dir.appendingPathComponent("model.json"))
        let manifest = ModelManifest(
            modelVersion: 1,
            modelFile: "model.safetensors",
            architectureFile: "model.json",
            rulesVersion: "fanfanqi-0",
            perceptionVersion: "m0",
            gameVersion: nil,
            datasetHash: "sha256:" + String(repeating: "0", count: 64),
            metrics: [:],
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))

        // 2. 从磁盘重新加载（走完整加载链路）
        let reloaded = try PolicyKit.load(directory: dir)

        // 3. 固定输入前向（全零特征）
        let features = MLX.zeros([1, arch.featureCount])
        let start = ContinuousClock.now
        let out = reloaded.forward(features: features)
        let latency = ContinuousClock.now - start

        // 4. 校验
        guard out.logits.count == arch.policyCount else {
            throw PolicyError.smokeFailed("policy 输出 \(out.logits.count) ≠ \(arch.policyCount)")
        }
        guard out.value.count == 1 else {
            throw PolicyError.smokeFailed("value 输出 \(out.value.count) ≠ 1")
        }
        guard out.logits.allSatisfy(\.isFinite), out.value.allSatisfy(\.isFinite) else {
            throw PolicyError.smokeFailed("输出含 NaN/Inf")
        }

        let original = PolicyKit(directory: dir, architecture: arch, manifest: manifest, net: net)
        let out0 = original.forward(features: features)
        let consistent = zip(out.logits, out0.logits).allSatisfy { abs($0 - $1) < 1e-5 }
            && zip(out.value, out0.value).allSatisfy { abs($0 - $1) < 1e-5 }
        guard consistent else {
            throw PolicyError.smokeFailed("safetensors 存取后输出不一致")
        }

        return SmokeReport(
            modelDirectory: dir.path,
            policyCount: out.logits.count,
            valueCount: out.value.count,
            latencyMS: latency / .milliseconds(1),
            reloadConsistent: consistent
        )
    }
}
