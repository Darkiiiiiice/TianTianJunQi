import Foundation
import Observation

/// 一局结果（`shared/schema/episode.schema.json` 的 `result`）。
enum EpisodeResult: String, Codable, Equatable, Sendable {
    case win
    case loss
    case draw
    case timeout
    case error
}

/// `meta.json`：严格只写 schema 允许的字段；模拟器专用信息不落这里。
struct EpisodeMeta: Codable, Equatable, Sendable {
    var id: String
    var mode: String
    var startedAt: String
    var duration: Double
    var moves: Int
    var result: EpisodeResult
    var score: Int?
}

/// `actions.jsonl` 的一行：遵循 `shared/schema/action.schema.json` 的 tap_cell。
///
/// 真实录制按“物理点击”记录：走棋是“点源格 → 点目标格”两行；Python 回放
/// 用动作前状态的 `selected` 推断走棋起点，因此不需要在动作里重复 from/to。
struct EpisodeTap: Codable, Equatable, Sendable {
    var type = "tap_cell"
    var cell: Int
}

/// `reward.json`：奖励按真实对局视角记录，训练端可据此重算。
struct EpisodeReward: Codable, Equatable, Sendable {
    var schema = 1
    var outcome: String
    var plies: Int
    var rewards: [String: Double]
}

enum EpisodeRecorderError: LocalizedError {
    case notRecording
    case missingInitialState
    case missingFinalState
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRecording: "当前没有在录制"
        case .missingInitialState: "没有可写的初始 GameState"
        case .missingFinalState: "录制结束前缺少最终 GameState"
        case .writeFailed(let reason): "episode 写入失败：\(reason)"
        }
    }
}

/// M2-7：把一局真实对局写成 `episodes/<id>/`。
///
/// 目录与 Python 端约定一致：
/// - `meta.json`   严格遵循 `shared/schema/episode.schema.json`；
/// - `states.jsonl` 每个动作前一行 + 终局一行；
/// - `actions.jsonl` 每个物理点击一行 `tap_cell`；
/// - `reward.json` 本局结果与回报。
///
/// 录制器只负责落盘，不判断规则/胜负；胜负由调用方（结果页 OCR 或人工）
/// 传入。文件写入在主线程完成，单局最多几百行 JSON，开销可忽略。
/// 线程约定：只在主线程调用；文件写入是同步的，单局数据量很小。
@Observable
final class EpisodeRecorder {
    private(set) var episodeID: String?
    private(set) var directoryURL: URL?
    private(set) var actionCount = 0
    private(set) var lastError: String?
    private(set) var isRecording = false

    @ObservationIgnored private let storage: StorageKit
    @ObservationIgnored private let mode: String
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var initialState: GameState?
    @ObservationIgnored private var statesHandle: FileHandle?
    @ObservationIgnored private var actionsHandle: FileHandle?
    @ObservationIgnored private var lastState: GameState?

    var statusText: String {
        if let lastError { return "录制失败：\(lastError)" }
        guard isRecording else { return "未录制" }
        return "录制中 · \(actionCount) 次点击 · \(episodeID ?? "")"
    }

    init(storage: StorageKit = StorageKit(), mode: String = "翻翻棋") {
        self.storage = storage
        self.mode = mode
    }

    // MARK: - 生命周期

    /// 开始一局；`initialState` 在第一次动作或结束时写入。
    func start(
        initialState: GameState? = nil,
        startedAt: Date = Date(),
        episodeID: String? = nil
    ) throws {
        guard !isRecording else { return }
        lastError = nil
        let fm = FileManager.default
        try fm.createDirectory(at: storage.episodesURL, withIntermediateDirectories: true)

        let baseID = episodeID ?? Self.makeID(startedAt)
        var identifier = baseID
        var suffix = 2
        while fm.fileExists(
            atPath: storage.episodesURL.appendingPathComponent(identifier).path
        ) {
            identifier = "\(baseID)-\(suffix)"
            suffix += 1
        }
        let directory = storage.episodesURL.appendingPathComponent(
            identifier, isDirectory: true
        )
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let statesURL = directory.appendingPathComponent("states.jsonl")
        let actionsURL = directory.appendingPathComponent("actions.jsonl")
        guard fm.createFile(atPath: statesURL.path, contents: nil),
              fm.createFile(atPath: actionsURL.path, contents: nil)
        else {
            throw EpisodeRecorderError.writeFailed("无法创建 states/actions")
        }
        do {
            statesHandle = try FileHandle(forWritingTo: statesURL)
            actionsHandle = try FileHandle(forWritingTo: actionsURL)
        } catch {
            throw EpisodeRecorderError.writeFailed(error.localizedDescription)
        }

        self.episodeID = identifier
        self.directoryURL = directory
        self.startedAt = startedAt
        self.initialState = initialState
        self.lastState = initialState
        self.actionCount = 0
        self.isRecording = true
    }

    /// 记录一次翻牌点击（动作前状态 = `state`）。
    func recordFlip(cell: Int, state: GameState) throws {
        try writeState(state)
        try append(EpisodeTap(cell: cell))
        lastState = state
    }

    /// 记录一次走棋：先点源格，再点目标格。
    ///
    /// 第二步的动作前状态是“源格已选中”；这是 UI 选中态，不是新的棋盘状态，
    /// 但对 `tap_cell` 回放是必要的（Python 用 `selected` 推断 from）。
    func recordMove(from: Int, to: Int, state: GameState) throws {
        try writeState(state)
        try append(EpisodeTap(cell: from))

        var selected = state
        selected.selected = from
        try writeState(selected)
        try append(EpisodeTap(cell: to))
        lastState = selected
    }

    /// 结束并写 meta/reward；`finalState` 是终局棋盘（结果页仍可读）。
    @discardableResult
    func finish(
        finalState: GameState?,
        result: EpisodeResult,
        score: Int? = nil
    ) throws -> URL {
        guard let directory = directoryURL else {
            throw EpisodeRecorderError.notRecording
        }
        if let finalState {
            try writeState(finalState)
            lastState = finalState
        } else if actionCount == 0, let initialState {
            try writeState(initialState)
            lastState = initialState
        } else if actionCount > 0 {
            throw EpisodeRecorderError.missingFinalState
        }

        let resolvedScore = score ?? Self.defaultScore(result)
        let meta = EpisodeMeta(
            id: episodeID ?? directory.lastPathComponent,
            mode: mode,
            startedAt: Self.iso8601(startedAt),
            duration: max(0, Date().timeIntervalSince(startedAt)),
            moves: actionCount,
            result: result,
            score: resolvedScore
        )
        try writeJSON(meta, to: directory.appendingPathComponent("meta.json"))
        let reward = EpisodeReward(
            outcome: result.rawValue,
            plies: actionCount,
            rewards: ["0": Double(resolvedScore)]
        )
        try writeJSON(reward, to: directory.appendingPathComponent("reward.json"))
        closeHandles()
        return directory
    }

    /// 放弃当前录制；默认删除半成品目录，避免训练端读到不完整 episode。
    func cancel(removeDirectory: Bool = true) {
        let directory = directoryURL
        closeHandles()
        if removeDirectory, let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        episodeID = nil
        directoryURL = nil
        actionCount = 0
        initialState = nil
        lastState = nil
    }

    // MARK: - 写盘

    private func writeState(_ state: GameState) throws {
        guard isRecording else { throw EpisodeRecorderError.notRecording }
        let line = try Self.jsonLine(state)
        try append(line: line, to: statesHandle)
    }

    private func append(_ tap: EpisodeTap) throws {
        guard isRecording else { throw EpisodeRecorderError.notRecording }
        let line = try Self.jsonLine(tap)
        try append(line: line, to: actionsHandle)
        actionCount += 1
    }

    private func append(line: Data, to handle: FileHandle?) throws {
        guard let handle else { throw EpisodeRecorderError.notRecording }
        do {
            try handle.write(contentsOf: line)
        } catch {
            lastError = error.localizedDescription
            throw EpisodeRecorderError.writeFailed(error.localizedDescription)
        }
    }

    private func closeHandles() {
        try? statesHandle?.close()
        try? actionsHandle?.close()
        statesHandle = nil
        actionsHandle = nil
        isRecording = false
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            lastError = error.localizedDescription
            throw EpisodeRecorderError.writeFailed(error.localizedDescription)
        }
    }

    private static func jsonLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func makeID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "real-\(formatter.string(from: date))"
    }

    private static func defaultScore(_ result: EpisodeResult) -> Int {
        switch result {
        case .win: 1
        case .loss, .timeout: -1
        case .draw, .error: 0
        }
    }
}
