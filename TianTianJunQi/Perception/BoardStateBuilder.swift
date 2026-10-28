import Foundation

struct BoardStateBuilderConfig: Equatable, Sendable {
    /// 我方执色（红/黑）；轮次证据「我方」会映射成这个颜色。
    var myColor: PieceColor = .red
    /// 是否把倒计时写入 GameState。
    var includeTimers = true
    /// 低于该置信度的明子不作为选子/可吃目标（与平滑器阈值保持一致）。
    var minPieceConfidence = 0.55
}

/// M1-5：稳定棋盘 + 轮次/计时 → `GameState`。
///
/// 只做状态构建，不含动作执行。`legal_actions` 是简化版（M2 规则引擎落地前的占位）：
/// - 未选中棋子：所有暗格（翻牌）+ 我方已翻明且置信度足够的棋子（选子）；
/// - 已选中我方明子：上下左右相邻的可进入格（空格/敌方明子）。
/// 不把暗格放进移动目标：翻牌是独立动作，移动不吃未翻开的子；
/// 这样即使“选中”这一步没生效，点目标格也不会误翻相邻暗子。
/// 铁路连线与行营规则尚未建模，等 M2 规则表确认后替换，调用方不要把它当完整合法走法。
struct BoardStateBuilder {
    var config: BoardStateBuilderConfig

    /// 上一次构建的棋盘，用于差分推断 `last_move`。
    private var previousCells: [CellObservation]?
    private var lastMove: GameMove?
    /// 当前轮次（颜色）。轮次证据缺失时保持上一次判断。
    private var turn: PieceColor

    init(config: BoardStateBuilderConfig = BoardStateBuilderConfig()) {
        self.config = config
        self.turn = config.myColor
    }

    var myColor: PieceColor {
        get { config.myColor }
        set { config.myColor = newValue }
    }

    mutating func reset() {
        previousCells = nil
        lastMove = nil
        turn = config.myColor
    }

    mutating func build(
        board: StabilizedBoard,
        phase: GamePhase = .playing,
        selected: Int? = nil,
        timers: BoardTimerReading? = nil
    ) -> GameState {
        if let signal = timers?.turn {
            switch signal {
            case .me: turn = config.myColor
            case .opponent: turn = config.myColor.opposite
            case .unknown: break
            }
        }

        updateLastMove(with: board)

        let actions = phase == .playing && !board.isSettling
            ? legalActions(board: board, turn: turn, selected: selected)
            : []

        return GameState(
            phase: phase,
            board: GameBoard(
                rows: board.rows,
                cols: board.cols,
                cells: board.cells.enumerated().map { index, cell in
                    GameCell(
                        i: index,
                        state: cell.state,
                        color: cell.state == .revealed ? cell.color : nil,
                        piece: cell.state == .revealed
                            ? cell.piece.flatMap { PieceCatalog.classifierID(forName: $0) ?? $0 }
                            : nil,
                        confidence: cell.state == .unknown ? nil : cell.confidence
                    )
                }
            ),
            turn: turn,
            selected: selected,
            legalActions: actions,
            timers: config.includeTimers ? timers.map { GameTimers(me: $0.me, opponent: $0.opponent) } : nil,
            lastMove: lastMove
        )
    }

    // MARK: - last_move

    private mutating func updateLastMove(with board: StabilizedBoard) {
        guard !board.isSettling else { return }
        defer { previousCells = board.cells }
        guard let previousCells else { return }

        let changed = board.cells.indices.filter { previousCells[$0] != board.cells[$0] }
        if let move = Self.inferMove(from: previousCells, to: board.cells, changed: changed) {
            lastMove = move
        } else if changed.count > 2 {
            // 整盘切换/新局：旧移动记录失效。
            lastMove = nil
        }
    }

    /// 恰好两格变化，且「离开格变空、到达格出现同一棋子」才认定为移动。
    /// 翻牌只改一格，不会产生 last_move。
    static func inferMove(
        from old: [CellObservation],
        to new: [CellObservation],
        changed: [Int]? = nil
    ) -> GameMove? {
        guard old.count == new.count else { return nil }
        let changed = changed ?? old.indices.filter { old[$0] != new[$0] }
        guard changed.count == 2 else { return nil }

        guard let from = changed.first(where: {
            old[$0].state != .empty && new[$0].state == .empty
        }), let to = changed.first(where: {
            old[$0].state == .empty && new[$0].state != .empty
        }) else { return nil }

        let source = old[from]
        let arrival = new[to]
        guard arrival.state == source.state,
              arrival.color == source.color,
              arrival.piece == source.piece
        else { return nil }
        return GameMove(from: from, to: to)
    }

    // MARK: - legal_actions

    private func legalActions(
        board: StabilizedBoard,
        turn: PieceColor,
        selected: Int?
    ) -> [Int] {
        let hidden = board.cells.indices.filter { board.cells[$0].state == .hidden }

        guard let selected,
              let cell = board.cell(row: selected / board.cols, col: selected % board.cols),
              cell.state == .revealed,
              cell.color == turn,
              cell.confidence >= config.minPieceConfidence
        else {
            // 未选中：翻牌 + 选我方明子。
            let own = board.cells.indices.filter {
                board.cells[$0].state == .revealed
                    && board.cells[$0].color == turn
                    && board.cells[$0].confidence >= config.minPieceConfidence
            }
            return Array(Set(hidden + own)).sorted()
        }

        let row = selected / board.cols
        let col = selected % board.cols
        let targets = Self.neighbors(row: row, col: col, rows: board.rows, cols: board.cols)
            .filter { index in
                let candidate = board.cells[index]
                switch candidate.state {
                case .empty:
                    return true
                case .revealed:
                    return candidate.color != turn
                case .hidden, .unknown:
                    return false
                }
            }

        return targets.sorted()
    }

    /// 四邻（不含对角线）；铁路/行营连线等规则待 M2 建模。
    static func neighbors(row: Int, col: Int, rows: Int, cols: Int) -> [Int] {
        var result: [Int] = []
        if row > 0 { result.append((row - 1) * cols + col) }
        if row < rows - 1 { result.append((row + 1) * cols + col) }
        if col > 0 { result.append(row * cols + col - 1) }
        if col < cols - 1 { result.append(row * cols + col + 1) }
        return result
    }
}

extension PieceColor {
    var opposite: PieceColor {
        self == .red ? .black : .red
    }
}
