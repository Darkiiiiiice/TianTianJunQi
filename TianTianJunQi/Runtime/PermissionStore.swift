import Foundation
import Observation

/// 单项权限状态。TCC 不区分"未请求"与"已拒绝"，统一报 notGranted。
enum PermissionStatus: Equatable, Sendable {
    case checking
    case granted
    case notGranted
}

/// 权限状态的 UI 侧存储：预检、请求、周期复查（设计文档 §9.6 授权失效复查）。
/// macOS 会周期性复查屏幕录制授权；由界面在启动、激活与 5 秒定时器时调用 refresh()。
@MainActor
@Observable
final class PermissionStore {
    private(set) var statuses: [PermissionKind: PermissionStatus] =
        Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .checking) })

    /// 已授权数量。
    var grantedCount: Int {
        PermissionKind.allCases.filter { statuses[$0] == .granted }.count
    }

    /// 是否全部授权。
    var allGranted: Bool {
        grantedCount == PermissionKind.allCases.count
    }

    /// M0-8 进入流程/抓帧只需要屏幕录制 + 辅助功能；
    /// 输入监控只在 M2-8 录制人类示范时需要，不应阻塞进入牌局。
    var controlReady: Bool {
        statuses[.screenRecording] == .granted && statuses[.accessibility] == .granted
    }

    /// 未授权的权限（用于概览页提示）。
    var missing: [PermissionKind] {
        PermissionKind.allCases.filter { statuses[$0] != .granted }
    }

    /// 重新预检全部权限。
    func refresh() {
        for kind in PermissionKind.allCases {
            statuses[kind] = PermissionCenter.isGranted(kind) ? .granted : .notGranted
        }
    }

    /// 发起授权请求（系统弹窗）。
    func request(_ kind: PermissionKind) {
        PermissionCenter.request(kind)
    }

    /// 打开对应系统设置面板。
    func openSettings(_ kind: PermissionKind) {
        PermissionCenter.openSettings(kind)
    }
}
