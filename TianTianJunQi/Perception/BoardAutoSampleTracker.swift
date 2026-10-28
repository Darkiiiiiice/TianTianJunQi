import CoreGraphics
import Foundation

/// 自动采样参数。改这里就能调灵敏度，不需要动采样循环。
struct BoardAutoSamplerConfig: Equatable, Sendable {
    /// 轮询间隔（秒）。只在对局界面运行。
    var pollInterval: TimeInterval = 0.25
    /// 棋盘静止多久后认为一次变化结束（秒）。
    var settleDuration: TimeInterval = 0.9
    /// 静置期间允许的画面漂移（占棋盘区域面积）。
    ///
    /// 实测：上一步棋子的选中框/高光会以约 2Hz 反复开关，整盘差在
    /// 0.4%–0.65% 之间跳动；这个值必须高于它，否则永远进不了静置状态。
    var settleTolerance: Double = 0.01
    /// 单格变化占比达到该值才可能是棋子本体变化。
    /// 实测：闪烁/动画的单格最高 42%，真实走棋最低 57%，阈值取中间。
    var cellMinFraction: Double = 0.5
    /// 单格平均差值达到该值才可能是棋子本体变化。
    /// 实测：闪烁/动画的单格均值最高 23，真实走棋最低 32。
    var cellMinMeanDelta: Double = 24
    /// 超过该比例视为整页切换（结算/弹窗/重开），保存前强制重新识别界面。
    var largeChange: Double = 0.15
    /// 保存后冷却，避免同一局面连拍。
    var cooldown: TimeInterval = 0.8
    /// 指纹缩略图宽度（像素）。
    var probeWidth: Int = BoardChangeDetector.defaultWidth
    /// 单通道差值阈值，低于它的像素视为未变化。
    var pixelDelta: Int = 20
    /// 单局自动保存上限，防止棋盘上有常驻动画时无限采集。
    var maxPerGame = 120
    /// 界面状态超过该时长没有刷新时，保存前强制重新识别。
    var screenStateMaxAge: TimeInterval = 2.5
}

/// 棋盘的格坐标（自动采样内部用来比较两次轮询的变化格）。
struct BoardCellID: Hashable, Sendable {
    let row: Int
    let col: Int
}

/// 一次采样判定的依据（日志/状态展示用）。
struct BoardAutoSampleChange: Equatable, Sendable {
    /// 发生「棋子本体变化」的格数；走棋/翻棋通常 1–2 格。
    let changedCells: Int
    /// 变化最大的那一格占格面积的比例（0…1）。
    let maxCellFraction: Double
    /// 整块棋盘区域的变化比例（0…1），用于识别整页切换。
    let boardFraction: Double
}

/// 纯值类型的变化跟踪器：把「什么时候该保存」从 UI/采集中拆出来，便于单测。
///
/// 一次保存需要同时满足：
/// 1. 棋盘已经静止 `settleDuration`（用「与静置参照帧的漂移」判断，
///    选中框闪烁落在容差内，缓慢动画会累积超限）；
/// 2. 至少有一格出现「棋子本体变化」（`cellDeltas`）；
/// 3. 距离上次保存超过 `cooldown`；
/// 4. 本局未超过 `maxPerGame`。
struct BoardAutoSampleTracker: Equatable {
    enum Action: Equatable {
        /// 还没有基线（刚进入对局）。
        case waiting
        /// 棋盘仍在动。
        case settling
        /// 已静止，但没有需要保存的变化（含冷却中）。
        case unchanged
        /// 应保存。
        case capture(BoardAutoSampleChange)
        /// 本局达到上限。
        case limitReached
    }

    var config: BoardAutoSamplerConfig

    /// 上一份成功采样的画面（或进入对局的第一帧）。
    private(set) var baseline: BoardFingerprint?
    /// 静置计时的参照帧：出现超过容差的漂移时推进到当前帧。
    private(set) var candidate: BoardFingerprint?
    private(set) var candidateAt: TimeInterval?
    private(set) var lastCaptureAt: TimeInterval?
    private(set) var gameCaptureCount = 0
    /// 最近一次判定中发生本体变化的格数（状态展示用）。
    private(set) var lastChangedCellCount = 0
    /// 上一次轮询里发生本体变化的格。下一次轮询仍是同一批格才算动画结束。
    private(set) var pendingCells: Set<BoardCellID>?

    init(config: BoardAutoSamplerConfig = BoardAutoSamplerConfig()) {
        self.config = config
    }

    /// 离开对局时清空跟踪状态（不清本局计数）。
    mutating func reset() {
        baseline = nil
        candidate = nil
        candidateAt = nil
        lastChangedCellCount = 0
        pendingCells = nil
    }

    /// 进入新的一局：清空跟踪与计数，等下一次观察重建基线。
    mutating func beginGame() {
        reset()
        lastCaptureAt = nil
        gameCaptureCount = 0
    }

    /// 保存成功后调用：把当前画面记为基线与静置参照，并进入冷却。
    mutating func recordCapture(_ probe: BoardFingerprint, at now: TimeInterval) {
        baseline = probe
        candidate = probe
        candidateAt = now
        lastCaptureAt = now
        gameCaptureCount += 1
        lastChangedCellCount = 0
        pendingCells = nil
    }

    mutating func observe(
        _ probe: BoardFingerprint,
        cellBoxes: [BoardCellBox],
        boardCorners: [CGPoint],
        at now: TimeInterval
    ) -> Action {
        guard baseline != nil else {
            self.baseline = probe
            self.candidate = probe
            self.candidateAt = now
            return .waiting
        }

        // 与静置参照帧比较：缓慢动画会累积成明显漂移，选中框闪烁则一直在容差内。
        let drift = BoardChangeDetector.changedFraction(
            candidate ?? probe,
            probe,
            boardCorners: boardCorners,
            pixelDelta: config.pixelDelta
        )

        // 指纹尺寸变了（窗口宽高比变化）：重建基线，不把 resize 当成棋子变化。
        guard let drift else {
            baseline = probe
            candidate = probe
            candidateAt = now
            return .waiting
        }

        if drift > config.settleTolerance {
            candidate = probe
            candidateAt = now
            return .settling
        }

        guard let candidateAt, now - candidateAt >= config.settleDuration else {
            return .settling
        }

        guard let baseline else {
            self.baseline = probe
            return .waiting
        }

        let deltas = BoardChangeDetector.cellDeltas(
            baseline,
            probe,
            boxes: cellBoxes,
            pixelDelta: config.pixelDelta
        )
        let changes = deltas.filter {
            $0.isPieceChange(
                minFraction: config.cellMinFraction,
                minMeanDelta: config.cellMinMeanDelta
            )
        }
        lastChangedCellCount = changes.count
        guard !changes.isEmpty else {
            pendingCells = nil
            return .unchanged
        }
        guard gameCaptureCount < config.maxPerGame else {
            pendingCells = nil
            return .limitReached
        }
        if let lastCaptureAt, now - lastCaptureAt < config.cooldown {
            pendingCells = nil
            return .unchanged
        }

        // 动画中途也可能出现一次「静止」；要求同一批格在下一次轮询里仍然变化。
        // 翻棋/走子动画继续推进时占比会变，但格集合不变，所以这道确认不会误伤。
        let cellIDs = Set(changes.map(\.id))
        if let pendingCells, pendingCells == cellIDs {
            self.pendingCells = nil
        } else {
            pendingCells = cellIDs
            return .settling
        }

        let boardFraction = BoardChangeDetector.changedFraction(
            baseline,
            probe,
            boardCorners: boardCorners,
            pixelDelta: config.pixelDelta
        ) ?? 0
        return .capture(
            BoardAutoSampleChange(
                changedCells: changes.count,
                maxCellFraction: changes.map(\.fraction).max() ?? 0,
                boardFraction: boardFraction
            )
        )
    }

}
