import Foundation

/// 屏幕状态（M1-7 七分类模型标签）。
///
/// rawValue 必须与 Core ML 模型里的类别名、`wgai screen-train` 的训练目录名一致：
/// `main` / `modeLobby` / `matching` / `board` / `result` / `popup` / `unknown`。
enum ScreenState: String, CaseIterable, Sendable, Identifiable {
    case main
    /// 场次选择页（新手场 / 普通场 / 大师场）。设计文档里也叫 modeLobby。
    case modeLobby
    /// 真人匹配等待页。
    case matching
    /// 牌局。
    case board
    /// 结算页（再来一局 / 切换对手）。
    case result
    /// 规则/公告/活动/提示弹窗。
    case popup
    /// 未识别 / 非工作流页面。模型和 OCR 都认不出时用它，交给上层暂停。
    case unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unknown: "未识别"
        case .main: "主菜单"
        case .modeLobby: "场次选择"
        case .matching: "匹配中"
        case .board: "牌局"
        case .result: "结算页"
        case .popup: "弹窗"
        }
    }

    /// 兼容旧分类器/旧日志里的 `venue` 标签。
    init?(classifierLabel: String) {
        if classifierLabel == "venue" {
            self = .modeLobby
        } else if let value = Self(rawValue: classifierLabel) {
            self = value
        } else {
            return nil
        }
    }
}

/// 模型与 OCR 的融合规则（纯逻辑，便于单测）。
///
/// 分类器为主、OCR 兜底；弹窗出现时必须暂停，所以允许 OCR 覆盖模型。
enum ScreenStateFusion {
    /// 识别结果来源，概览页/日志用。
    enum Source: String, Sendable {
        case model = "模型"
        case ocr = "OCR"
        case none = "—"
    }

    static func resolve(
        modelLabel: String?,
        confidence: Double,
        ocrState: ScreenState,
        minConfidence: Double = 0.60
    ) -> (state: ScreenState, source: Source) {
        guard let modelLabel,
              confidence >= minConfidence,
              let modelState = ScreenState(classifierLabel: modelLabel)
        else {
            return (ocrState, ocrState == .unknown ? .none : .ocr)
        }

        // 弹窗一出现就必须暂停，宁可 OCR 多报一次，也不能让模型把弹窗当牌局。
        if ocrState == .popup, modelState != .popup {
            return (.popup, .ocr)
        }
        // 模型对 unknown 有高置信度、OCR 却命中关键字时，以 OCR 为准（模型漏训的界面）。
        if modelState == .unknown, ocrState != .unknown {
            return (ocrState, .ocr)
        }
        return (modelState, .model)
    }
}
