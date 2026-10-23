import Foundation
import Observation

/// 应用运行状态机（设计文档 §3.2 的 12 个状态）。
enum AppState: String, CaseIterable, Sendable {
    case idle
    case waitingWindow
    case verifying
    case enteringMode
    case matching
    case ready
    case playing
    case recording
    case training
    case evaluating
    case paused
    case failed

    var label: String {
        switch self {
        case .idle: "空闲"
        case .waitingWindow: "等待游戏窗口"
        case .verifying: "识别界面"
        case .enteringMode: "进入翻翻棋"
        case .matching: "等待匹配"
        case .ready: "牌局就绪"
        case .playing: "自动对局"
        case .recording: "录制示范"
        case .training: "训练中"
        case .evaluating: "评测中"
        case .paused: "已暂停"
        case .failed: "失败"
        }
    }
}

/// 一次状态迁移记录。
struct AppStateChange: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let from: AppState
    let to: AppState
    let reason: String

    init(from: AppState, to: AppState, reason: String) {
        self.timestamp = Date()
        self.from = from
        self.to = to
        self.reason = reason
    }
}

/// UI 侧状态存储：持有当前状态与迁移日志（环形缓冲，容量 500）。
/// M0-2 骨架阶段由日志页的调试选择器手动驱动；后续由 SessionKit 的会话 actor 驱动迁移。
@MainActor
@Observable
final class AppStateStore {
    private(set) var state: AppState = .idle
    private(set) var changes: [AppStateChange] = []

    private let capacity = 500

    /// 迁移到新状态；相同状态忽略。
    func transition(to newState: AppState, reason: String) {
        guard newState != state else { return }
        changes.append(AppStateChange(from: state, to: newState, reason: reason))
        if changes.count > capacity {
            changes.removeFirst(changes.count - capacity)
        }
        state = newState
    }
}
