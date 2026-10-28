import Foundation

/// `shared/schema/game_state.schema.json` 的 Swift 映射。
///
/// 只做序列化，不含规则判断；`phase` 目前由调用方给出（结算页 → result）。
struct GameState: Codable, Equatable, Sendable {
    /// schema 版本，固定 1。
    var schema = 1
    var phase: GamePhase
    var board: GameBoard
    var turn: PieceColor
    var selected: Int?
    var legalActions: [Int]
    var timers: GameTimers?
    var lastMove: GameMove?

    enum CodingKeys: String, CodingKey {
        case schema, phase, board, turn, selected
        case legalActions = "legal_actions"
        case timers
        case lastMove = "last_move"
    }

    func jsonData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }

    func jsonString() -> String? {
        jsonData().flatMap { String(data: $0, encoding: .utf8) }
    }
}

enum GamePhase: String, Codable, Sendable {
    case playing
    case result
}

struct GameBoard: Codable, Equatable, Sendable {
    var rows: Int
    var cols: Int
    var cells: [GameCell]
}

/// 一格序列化结果；`i` 是行优先索引。
/// `piece` 用分类器 ID（如 `commander`），不是中文名，便于与训练端/规则表对齐。
struct GameCell: Codable, Equatable, Sendable {
    var i: Int
    var state: CellState
    var color: PieceColor?
    var piece: String?
    var confidence: Double?
}

/// 双方剩余倒计时（秒）；未知为 nil。
struct GameTimers: Codable, Equatable, Sendable {
    var me: Double?
    var opponent: Double?
}

/// 最近一次移动；翻牌不算移动。
struct GameMove: Codable, Equatable, Sendable {
    var from: Int
    var to: Int
}
