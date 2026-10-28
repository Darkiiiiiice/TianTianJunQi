import CoreGraphics
import Foundation

/// M1-6 点击动作：翻牌或“选子 → 落子”。
enum BoardTapAction: Equatable, Sendable {
    /// 翻一格暗子。
    case flip(cell: Int)
    /// 选中我方明子后点击目标格（吃子/空格都算）。
    case move(from: Int, to: Int)

    var changedIndices: [Int] {
        switch self {
        case .flip(let cell):
            [cell]
        case .move(let from, let to):
            [from, to]
        }
    }

    var label: String {
        switch self {
        case .flip(let cell): "翻牌 \(cell)"
        case .move(let from, let to): "移动 \(from) → \(to)"
        }
    }
}

/// 点击前的拒绝原因：这些情况一个事件都不发。
enum BoardTapRefusal: Equatable, Sendable {
    case disarmed
    case notInBoard
    case bannerVisible
    case perceptionNotRunning
    case noStableBoard
    case settling
    case notMyTurn
    case phaseNotPlaying
    case indexOutOfRange(Int)
    case cellNotHidden(Int)
    case sourceNotOwnPiece(Int)
    case destinationNotLegal(Int)
    case noWindow
    case noCalibration
    case noFrame
    case offScreen
    case busy

    var message: String {
        switch self {
        case .disarmed: "未开启点击"
        case .notInBoard: "当前不在牌局界面"
        case .bannerVisible: "开局横幅遮挡棋盘"
        case .perceptionNotRunning: "实时感知未运行"
        case .noStableBoard: "尚无稳定棋盘"
        case .settling: "棋盘仍在变化（冻结期）"
        case .notMyTurn: "还没轮到我方"
        case .phaseNotPlaying: "当前不是对局进行中"
        case .indexOutOfRange(let index): "格索引越界 \(index)"
        case .cellNotHidden(let index): "第 \(index) 格不是暗子"
        case .sourceNotOwnPiece(let index): "第 \(index) 格不是我方明子"
        case .destinationNotLegal(let index): "第 \(index) 格不在可走集合内"
        case .noWindow: "没有可用的游戏窗口"
        case .noCalibration: "棋盘未校准"
        case .noFrame: "还没有抓到画面"
        case .offScreen: "点击目标在屏幕外"
        case .busy: "上一次点击还没结束"
        }
    }
}

/// 点击结果：成功必须由棋盘变化证实，绝不假设点击生效。
enum BoardTapResult: Equatable, Sendable {
    /// `changed` 是与点击前相比发生变化的格数（可含动画噪声）。
    case confirmed(changed: Int)
    case refused(BoardTapRefusal)
    case unverified(String)

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }

    var text: String {
        switch self {
        case .confirmed(let changed):
            "已验证（\(changed) 格变化）"
        case .refused(let refusal):
            "未点击：\(refusal.message)"
        case .unverified(let reason):
            "未验证：\(reason)"
        }
    }
}

/// 归一化坐标换算：格子中心（内容区）→ 窗口归一化 → InputInjector。
///
/// 校准与分类都用“裁剪后的内容区”归一化坐标，而 `InputInjector.click` 接收
/// “窗口”归一化坐标；两者之间只差 `CapturedFrame.contentRect`，绝不能混用。
enum BoardTapGeometry {
    static func contentCenter(of index: Int, grid: BoardGrid) -> CGPoint? {
        guard (0..<(grid.rows * grid.cols)).contains(index) else { return nil }
        return grid.cellCenters[index]
    }

    static func windowPoint(content: CGPoint, contentRect: CGRect) -> CGPoint {
        CGPoint(
            x: contentRect.minX + content.x * contentRect.width,
            y: contentRect.minY + content.y * contentRect.height
        )
    }

    static func windowPoint(
        of index: Int,
        grid: BoardGrid,
        contentRect: CGRect
    ) -> CGPoint? {
        guard let content = contentCenter(of: index, grid: grid) else { return nil }
        return windowPoint(content: content, contentRect: contentRect)
    }

    /// 点击前的基本校验（不含轮次/动作合法性）。
    static func isTappable(_ point: CGPoint) -> Bool {
        (-0.02...1.02).contains(point.x) && (-0.02...1.02).contains(point.y)
    }
}

/// 动作合法性 + 期望结果判定（纯函数，便于单测与回放）。
enum BoardTapVerifier {
    /// 点击前的拒绝检查；返回 nil 表示可以发事件。
    static func refusal(
        for action: BoardTapAction,
        board: StabilizedBoard,
        turn: PieceColor,
        myColor: PieceColor,
        legalActions: [Int],
        phase: GamePhase,
        minPieceConfidence: Double
    ) -> BoardTapRefusal? {
        guard phase == .playing else { return .phaseNotPlaying }
        guard !board.isSettling else { return .settling }
        guard turn == myColor else { return .notMyTurn }

        let count = board.rows * board.cols
        func inRange(_ index: Int) -> Bool { (0..<count).contains(index) }

        switch action {
        case .flip(let cell):
            guard inRange(cell) else { return .indexOutOfRange(cell) }
            guard board.cells[cell].state == .hidden else { return .cellNotHidden(cell) }
            return nil

        case .move(let from, let to):
            guard inRange(from) else { return .indexOutOfRange(from) }
            guard inRange(to) else { return .indexOutOfRange(to) }
            guard from != to else { return .destinationNotLegal(to) }
            let source = board.cells[from]
            guard source.state == .revealed,
                  source.color == myColor,
                  source.confidence >= minPieceConfidence
            else { return .sourceNotOwnPiece(from) }
            guard legalActions.contains(to) else { return .destinationNotLegal(to) }
            return nil
        }
    }

    /// 棋盘是否已呈现动作的预期结果。
    static func isSatisfied(
        _ action: BoardTapAction,
        before: [CellObservation],
        after: [CellObservation]
    ) -> Bool {
        guard before.count == after.count else { return false }
        switch action {
        case .flip(let cell):
            guard (0..<after.count).contains(cell) else { return false }
            return before[cell].state == .hidden
                && after[cell].state == .revealed
                && after[cell].isActionable

        case .move(let from, let to):
            guard (0..<after.count).contains(from), (0..<after.count).contains(to),
                  from != to
            else { return false }
            let source = before[from]
            let arrival = after[to]
            return source.state == .revealed
                && after[from].state == .empty
                && arrival.state == .revealed
                && arrival.color == source.color
                && arrival.piece == source.piece
        }
    }

    /// 超时后用一句话说明卡在哪一步，写日志。
    static func mismatch(
        _ action: BoardTapAction,
        before: [CellObservation],
        after: [CellObservation]
    ) -> String {
        guard before.count == after.count else {
            return "棋盘尺寸变化（\(before.count) → \(after.count)）"
        }
        switch action {
        case .flip(let cell):
            guard (0..<after.count).contains(cell) else { return "格索引越界 \(cell)" }
            let current = after[cell]
            if current.state == .hidden { return "第 \(cell) 格仍是暗子" }
            if current.state == .unknown { return "第 \(cell) 格分类不可用" }
            if current.state == .empty { return "第 \(cell) 格被识别为空" }
            if !current.isActionable { return "第 \(cell) 格缺少颜色/军衔" }
            return "第 \(cell) 格未呈现翻牌结果"

        case .move(let from, let to):
            guard (0..<after.count).contains(from), (0..<after.count).contains(to) else {
                return "格索引越界"
            }
            if after[from].state != .empty { return "源格 \(from) 未变空" }
            let source = before[from]
            let arrival = after[to]
            if arrival.state != .revealed { return "目标格 \(to) 没有棋子" }
            if arrival.color != source.color || arrival.piece != source.piece {
                return "目标格棋子与移动前不一致"
            }
            return "未观察到移动结果"
        }
    }

    static func changedCount(before: [CellObservation], after: [CellObservation]) -> Int {
        guard before.count == after.count else { return abs(before.count - after.count) }
        return zip(before, after).reduce(into: 0) { count, pair in
            if pair.0 != pair.1 { count += 1 }
        }
    }
}
