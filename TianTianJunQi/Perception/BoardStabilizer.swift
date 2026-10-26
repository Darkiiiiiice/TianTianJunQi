import Foundation

/// 单格感知结果（M1-3 分类器输出 → M1-4 时序平滑输入）。
/// `state` 为 unknown 时表示分类器无法判断；平滑器不会用 unknown 覆盖已知稳定状态。
enum CellState: String, Codable, CaseIterable, Sendable {
    case empty
    case hidden
    case revealed
    case unknown
}

enum PieceColor: String, Codable, CaseIterable, Sendable {
    case red
    case black
}

struct CellObservation: Equatable, Sendable {
    var state: CellState
    var color: PieceColor?
    var piece: String?
    /// 0...1，分类器置信度。
    var confidence: Double

    init(
        state: CellState,
        color: PieceColor? = nil,
        piece: String? = nil,
        confidence: Double = 1
    ) {
        self.state = state
        self.confidence = min(max(confidence, 0), 1)
        switch state {
        case .empty, .hidden, .unknown:
            self.color = nil
            self.piece = nil
        case .revealed:
            self.color = color
            self.piece = piece?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func empty(confidence: Double = 1) -> CellObservation {
        CellObservation(state: .empty, confidence: confidence)
    }

    static func hidden(confidence: Double = 1) -> CellObservation {
        CellObservation(state: .hidden, confidence: confidence)
    }

    static func revealed(
        _ color: PieceColor,
        _ piece: String,
        confidence: Double = 1
    ) -> CellObservation {
        CellObservation(state: .revealed, color: color, piece: piece, confidence: confidence)
    }

    static func unknown(confidence: Double = 0) -> CellObservation {
        CellObservation(state: .unknown, confidence: confidence)
    }

    /// revealed 必须同时有颜色和棋子名，否则不能作为可行动信息。
    var isActionable: Bool {
        guard state == .revealed else { return state != .unknown }
        return color != nil && piece?.isEmpty == false
    }
}

/// 一帧完整棋盘观察；索引为行优先 `row * cols + col`。
struct BoardObservation: Equatable, Sendable {
    let rows: Int
    let cols: Int
    let cells: [CellObservation]

    init?(rows: Int, cols: Int, cells: [CellObservation]) {
        guard rows > 0, cols > 0, cells.count == rows * cols else { return nil }
        self.rows = rows
        self.cols = cols
        self.cells = cells
    }

    static func unknown(rows: Int, cols: Int, confidence: Double = 0) -> BoardObservation? {
        guard rows > 0, cols > 0 else { return nil }
        return BoardObservation(
            rows: rows,
            cols: cols,
            cells: Array(repeating: .unknown(confidence: confidence), count: rows * cols)
        )
    }

    func cell(row: Int, col: Int) -> CellObservation? {
        guard (0..<rows).contains(row), (0..<cols).contains(col) else { return nil }
        return cells[row * cols + col]
    }

    var actionableCount: Int { cells.filter(\.isActionable).count }
}

struct BoardStabilizerConfig: Equatable, Sendable {
    /// 参与投票的最近帧数（计划 M1-4：2–3 帧）。
    var windowSize = 3
    /// 至少多少帧一致才更新稳定状态。
    var requiredVotes = 2
    /// 低于该置信度的观察直接丢弃，避免动画/遮挡污染投票。
    var minConfidence = 0.55
    /// 超过该时长的观察不再参与投票（秒）。
    var maxObservationAge: TimeInterval = 1.5
    /// 棋盘级大变化（开局/再来一局）需静置多久才提交（秒）。
    var settleDuration: TimeInterval = 0.35
    /// 与稳定状态差异达到多少格视为“整盘切换”，进入冻结。
    var transitionCellCount = 4

    var isValid: Bool {
        windowSize >= 1
            && requiredVotes >= 1
            && requiredVotes <= windowSize
            && minConfidence >= 0
            && minConfidence <= 1
            && maxObservationAge >= 0
            && settleDuration >= 0
            && transitionCellCount >= 1
    }
}

/// 平滑后的棋盘快照。`isSettling == true` 时上层应等待，不要发动作。
struct StabilizedBoard: Equatable, Sendable {
    let rows: Int
    let cols: Int
    let cells: [CellObservation]
    /// 与上一次输出相比发生变化的格数。
    let changedCells: Int
    /// 检测到棋盘级变化，仍在等待动画结束。
    let isSettling: Bool
    let updatedAt: TimeInterval

    var actionableCount: Int { cells.filter(\.isActionable).count }

    func cell(row: Int, col: Int) -> CellObservation? {
        guard (0..<rows).contains(row), (0..<cols).contains(col) else { return nil }
        return cells[row * cols + col]
    }
}

/// M1-4 时序平滑：逐格多数投票 + 置信度过滤 + 棋盘级动画冻结。
///
/// 输入是分类器每帧的原始观察，输出可直接用于 BoardStateBuilder。
/// 设计上不依赖具体分类器，纯值类型、可注入时间，便于单测与回放。
struct BoardStabilizer {
    private struct VoteKey: Hashable {
        let state: CellState
        let color: PieceColor?
        let piece: String?
    }

    private struct Sample {
        let at: TimeInterval
        let observation: CellObservation
    }

    var config: BoardStabilizerConfig

    private var rows = 0
    private var cols = 0
    private var history: [[Sample]] = []
    private var stable: [CellObservation] = []
    private var hasStable = false
    private var pending: [CellObservation]?
    private var pendingSince: TimeInterval?
    private var lastOutput: StabilizedBoard?

    init(config: BoardStabilizerConfig = BoardStabilizerConfig()) {
        precondition(config.isValid, "BoardStabilizerConfig 参数不合法")
        self.config = config
    }

    mutating func reset() {
        rows = 0
        cols = 0
        history = []
        stable = []
        hasStable = false
        pending = nil
        pendingSince = nil
        lastOutput = nil
    }

    /// 喂入一帧观察。返回当前稳定棋盘；输入尺寸与已初始化棋盘不一致时重置。
    /// 返回 nil 仅当观察本身无效（行列/格数不匹配）。
    mutating func update(
        _ observation: BoardObservation,
        at time: TimeInterval
    ) -> StabilizedBoard? {
        guard observation.rows > 0, observation.cols > 0,
              observation.cells.count == observation.rows * observation.cols
        else { return nil }

        if observation.rows != rows || observation.cols != cols {
            reset()
            rows = observation.rows
            cols = observation.cols
            history = Array(repeating: [], count: rows * cols)
            stable = Array(repeating: .unknown(), count: rows * cols)
        }

        let count = rows * cols
        for index in 0..<count {
            let cell = observation.cells[index]
            guard cell.confidence >= config.minConfidence, cell.state != .unknown else {
                // 低置信度/unknown 不投票，保留历史稳定值。
                continue
            }
            history[index].append(Sample(at: time, observation: cell))
            if history[index].count > config.windowSize {
                history[index].removeFirst(history[index].count - config.windowSize)
            }
        }

        let candidate = (0..<count).map { index -> CellObservation in
            vote(at: index, now: time) ?? stable[index]
        }

        let previous = hasStable ? stable : nil
        let changedFromStable = previous.map { difference(candidate, $0) } ?? count

        // 第一次拿到足够票数：直接建立稳定状态。
        if !hasStable {
            if candidate.contains(where: { $0.state != .unknown }) {
                stable = candidate
                hasStable = true
            }
            let output = makeOutput(
                cells: stable,
                previous: lastOutput,
                settling: false,
                at: time
            )
            lastOutput = output
            return output
        }

        var settling = false
        if changedFromStable >= config.transitionCellCount {
            settling = true
            if let pending, difference(candidate, pending) <= max(2, count / 100) {
                // 同一场动画的后续帧：保持起始时间，等待静置。
            } else {
                pending = candidate
                pendingSince = time
            }

            if let pendingSince,
               time - pendingSince >= config.settleDuration,
               let pending {
                stable = pending
                self.pending = nil
                self.pendingSince = nil
                settling = false
            }
        } else {
            // 变化不足棋盘级：逐格直接接受（翻牌/移动通常只影响少量格子）。
            pending = nil
            pendingSince = nil
            stable = candidate
        }

        let output = makeOutput(
            cells: stable,
            previous: lastOutput,
            settling: settling,
            at: time
        )
        lastOutput = output
        return output
    }

    // MARK: - Voting

    private func vote(at index: Int, now: TimeInterval) -> CellObservation? {
        let samples = history[index].filter {
            now - $0.at <= config.maxObservationAge && $0.at <= now
        }
        guard samples.count >= config.requiredVotes else { return nil }

        var weights: [VoteKey: Double] = [:]
        var confidenceSums: [VoteKey: Double] = [:]
        var counts: [VoteKey: Int] = [:]
        for sample in samples {
            let cell = sample.observation
            guard cell.isActionable || cell.state == .hidden || cell.state == .empty else {
                continue
            }
            let key = VoteKey(state: cell.state, color: cell.color, piece: cell.piece)
            weights[key, default: 0] += cell.confidence
            confidenceSums[key, default: 0] += cell.confidence
            counts[key, default: 0] += 1
        }

        guard let winner = weights.max(by: { lhs, rhs in
            if abs(lhs.value - rhs.value) < 1e-9 {
                // 平局时交给调用方降级为 unknown（用键的确定性比较避免随机结果）。
                return keyOrder(lhs.key) < keyOrder(rhs.key)
            }
            return lhs.value < rhs.value
        }) else { return nil }

        let total = weights.values.reduce(0, +)
        guard total > 0, winner.value > total / 2 else { return nil }

        let winnerCount = Double(counts[winner.key] ?? 0)
        let confidence = winnerCount > 0
            ? min(1, (confidenceSums[winner.key] ?? 0) / winnerCount)
            : 0
        return CellObservation(
            state: winner.key.state,
            color: winner.key.color,
            piece: winner.key.piece,
            confidence: confidence
        )
    }

    private func keyOrder(_ key: VoteKey) -> String {
        "\(key.state.rawValue)|\(key.color?.rawValue ?? "")|\(key.piece ?? "")"
    }

    private func difference(_ lhs: [CellObservation], _ rhs: [CellObservation]) -> Int {
        zip(lhs, rhs).reduce(0) { count, pair in
            count + (pair.0.state == pair.1.state
                && pair.0.color == pair.1.color
                && pair.0.piece == pair.1.piece ? 0 : 1)
        }
    }

    private func makeOutput(
        cells: [CellObservation],
        previous: StabilizedBoard?,
        settling: Bool,
        at time: TimeInterval
    ) -> StabilizedBoard {
        let changed = previous.map { difference(cells, $0.cells) } ?? cells.count
        return StabilizedBoard(
            rows: rows,
            cols: cols,
            cells: cells,
            changedCells: changed,
            isSettling: settling,
            updatedAt: time
        )
    }
}
