import Foundation

/// 旁观录制（M2-7 观察模式）反推出来的真实动作。
enum EpisodeInferredAction: Equatable, Sendable {
    case flip(cell: Int)
    case move(from: Int, to: Int)

    var label: String {
        switch self {
        case .flip(let cell): "翻牌 \(cell)"
        case .move(let from, let to): "移动 \(from) → \(to)"
        }
    }
}

/// 相邻两个稳定棋盘之间的差分结论。
enum EpisodeObservation: Equatable, Sendable {
    /// 棋盘没有实质变化（轮次/计时/选中变化不算动作）。
    case unchanged
    /// 唯一解释：可以安全写出该动作。
    case recorded(EpisodeInferredAction)
    /// 本帧存在未识别格子，先不要比对。
    case unstable
    /// 变化无法唯一解释；调用方应结束当前 episode 并重新开一段。
    case ambiguous(String)
}

/// 旁观录制：从两个稳定 `GameState` 的棋盘差分反推真实动作。
///
/// 只认可以**唯一确定起止格**的转移：
/// 1. 单格 hidden → revealed：翻牌；
/// 2. 一格离场 + 一格由空变有、棋子身份相同：走子到空格；
/// 3. 一格离场 + 一格明子换人、身份与离场棋子相同：吃子获胜；
/// 4. 一格离场 + 一格暗子翻开：攻击暗子后进攻方阵亡（撞暗雷/暗子更大）；
/// 5. 两格同时变空：同归于尽，按轮次颜色区分进攻方。
///
/// 其余情况（多点同时变化、无法定位目标等）一律判 `ambiguous`。
/// 宁可丢一段数据，也不写可能错误的对局——M2-6 的规则回归不能有假阳性。
enum EpisodeTransitionInference {
    struct Fingerprint: Equatable {
        let state: CellState
        let color: PieceColor?
        let piece: String?

        init(_ cell: GameCell) {
            state = cell.state
            color = cell.color
            piece = cell.piece
        }
    }

    static func infer(from previous: GameState, to next: GameState) -> EpisodeObservation {
        guard next.phase == .playing else { return .unchanged }
        guard previous.board.rows == next.board.rows,
              previous.board.cols == next.board.cols,
              previous.board.cells.count == next.board.cells.count
        else { return .ambiguous("棋盘尺寸变化") }
        guard !next.board.cells.contains(where: { $0.state == .unknown }) else {
            return .unstable
        }
        guard !previous.board.cells.contains(where: { $0.state == .unknown }) else {
            return .unstable
        }

        var departed: [Int] = []
        var arrived: [Int] = []
        var revealed: [Int] = []
        var morphed: [Int] = []

        for index in previous.board.cells.indices {
            let old = previous.board.cells[index]
            let new = next.board.cells[index]
            if old.state == new.state, old.color == new.color, old.piece == new.piece {
                continue
            }
            if old.state != .empty, new.state == .empty {
                departed.append(index)
            } else if old.state == .empty, new.state != .empty {
                arrived.append(index)
            } else if old.state == .hidden, new.state == .revealed {
                revealed.append(index)
            } else if old.state == .revealed, new.state == .revealed {
                morphed.append(index)
            } else {
                return .ambiguous(
                    "格子 \(index) 变化无法解释：\(old.state.rawValue) → \(new.state.rawValue)"
                )
            }
        }

        if departed.isEmpty, arrived.isEmpty, revealed.isEmpty, morphed.isEmpty {
            return .unchanged
        }

        if departed.isEmpty, arrived.isEmpty, morphed.isEmpty, revealed.count == 1 {
            return .recorded(.flip(cell: revealed[0]))
        }

        if departed.count == 1, arrived.count == 1, revealed.isEmpty, morphed.isEmpty,
           Fingerprint(previous.board.cells[departed[0]])
            == Fingerprint(next.board.cells[arrived[0]])
        {
            return .recorded(.move(from: departed[0], to: arrived[0]))
        }

        if departed.count == 1, arrived.isEmpty, revealed.isEmpty, morphed.count == 1,
           Fingerprint(previous.board.cells[departed[0]])
            == Fingerprint(next.board.cells[morphed[0]])
        {
            return .recorded(.move(from: departed[0], to: morphed[0]))
        }

        if departed.count == 1, arrived.isEmpty, morphed.isEmpty, revealed.count == 1 {
            return .recorded(.move(from: departed[0], to: revealed[0]))
        }

        if departed.count == 2, arrived.isEmpty, revealed.isEmpty, morphed.isEmpty {
            // 同归于尽：两格都空，方向不影响回放校验，但仍按轮次颜色尽量还原。
            let from = departed.first {
                previous.board.cells[$0].color == previous.turn
            } ?? departed[0]
            let to = departed.first { $0 != from } ?? departed[1]
            return .recorded(.move(from: from, to: to))
        }

        return .ambiguous(
            "变化集合无法唯一解释（离场 \(departed.count)、到达 \(arrived.count)、"
                + "翻开 \(revealed.count)、换子 \(morphed.count)）"
        )
    }
}
