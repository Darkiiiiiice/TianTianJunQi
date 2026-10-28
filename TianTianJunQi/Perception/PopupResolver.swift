import CoreGraphics
import Foundation

/// 已知弹窗类型（M1-8）。
///
/// 只把「已实测过文案/锚点」的弹窗列进来；列表之外的弹窗一律按未知处理：
/// 暂停 + 截图，绝不盲点。
enum PopupKind: String, CaseIterable, Sendable, Equatable {
    /// 退出确认：只能点「取消」，永远不能点「确定」。
    case exitConfirm
    /// 登录奖励 / 每日签到弹层。
    case signIn
    /// 每日任务 / 成长任务弹层。
    case task
    /// 个人信息弹层。
    case profile
    /// 游戏规则 / 玩法说明。
    case rules
    /// 公告 / 更新公告。
    case announcement
    /// 断线重连提示。
    case disconnect
    /// 广告弹窗：设计上暂停，不尝试观看/跳过。
    case ad
    /// 实名 / 防沉迷：暂停，不尝试绕过。
    case realName
    /// 强制/可选版本更新：暂停，不自动更新。
    case update

    var label: String {
        switch self {
        case .exitConfirm: "退出确认"
        case .signIn: "登录奖励"
        case .task: "任务"
        case .profile: "个人信息"
        case .rules: "规则说明"
        case .announcement: "公告"
        case .disconnect: "断线重连"
        case .ad: "广告"
        case .realName: "实名/防沉迷"
        case .update: "版本更新"
        }
    }
}

/// 关闭弹窗时的落点。
enum PopupCloseTarget: Equatable, Sendable {
    /// OCR 命中后点击文字中心。
    case keyword(String)
    /// 校准锚点键；没有校准时使用模板内置锚点。
    case anchor(String)

    var label: String {
        switch self {
        case .keyword(let keyword): "文字「\(keyword)」"
        case .anchor(let key): "锚点 \(key)"
        }
    }
}

/// 对已知弹窗的处理方式。
enum PopupAction: Equatable, Sendable {
    case close(PopupCloseTarget)
    /// 需要人工处理，暂停并截图。
    case pause(String)
}

/// 单次弹窗识别结果。
enum PopupResolution: Equatable, Sendable {
    case unknown
    case known(kind: PopupKind, action: PopupAction, matched: [String])

    var kind: PopupKind? {
        guard case .known(let kind, _, _) = self else { return nil }
        return kind
    }

    var action: PopupAction? {
        guard case .known(_, let action, _) = self else { return nil }
        return action
    }

    var matched: [String] {
        guard case .known(_, _, let matched) = self else { return [] }
        return matched
    }

    var label: String {
        switch self {
        case .unknown: "未知弹窗"
        case .known(let kind, _, _): kind.label
        }
    }

    var summary: String {
        switch self {
        case .unknown:
            return "未匹配已知模板"
        case .known(let kind, let action, let matched):
            let hits = matched.isEmpty ? "—" : matched.joined(separator: "、")
            switch action {
            case .close(let target):
                return "\(kind.label) · \(hits) → \(target.label)"
            case .pause(let reason):
                return "\(kind.label) · \(hits) → 暂停（\(reason)）"
            }
        }
    }
}

/// 模板定义。`signatures` 是强特征，任一命中即认为属于该弹窗；
/// `closeKeywords` 优先于 `closeAnchor`，避免锚点在弹层布局变化时点偏。
struct PopupTemplate: Equatable, Sendable {
    let kind: PopupKind
    let signatures: [String]
    let closeKeywords: [String]
    let closeAnchor: String?
    /// 非 nil 表示已知但不自动关闭，必须暂停。
    let pauseReason: String?
}

/// 已知弹窗目录（M1-8 v1）。
///
/// 顺序即优先级：退出确认最先（误点「确定」会判负扣费），
/// 签到其次（签到弹层里也含「看广告」文案，必须先于广告模板匹配）。
enum PopupCatalog {
    /// 每次进入流程最多关闭 3 轮；超过仍停在弹窗则暂停截图。
    static let maxCloseRounds = 3

    static let templates: [PopupTemplate] = [
        PopupTemplate(
            kind: .exitConfirm,
            signatures: ["确定要退出", "现在退出将被判负", "扣除双倍"],
            closeKeywords: ["取消"],
            closeAnchor: nil,
            pauseReason: nil
        ),
        PopupTemplate(
            kind: .signIn,
            signatures: ["登录奖励", "本月累计签到", "累计签到"],
            closeKeywords: ["关闭", "取消"],
            closeAnchor: PopupAnchor.signInClose.rawValue,
            pauseReason: nil
        ),
        PopupTemplate(
            kind: .task,
            signatures: ["每日任务", "成长任务", "去完成"],
            closeKeywords: ["关闭", "取消"],
            closeAnchor: PopupAnchor.taskClose.rawValue,
            pauseReason: nil
        ),
        PopupTemplate(
            kind: .profile,
            signatures: ["个人信息", "游戏ID", "四国胜率"],
            closeKeywords: ["关闭", "取消"],
            closeAnchor: PopupAnchor.profileClose.rawValue,
            pauseReason: nil
        ),
        PopupTemplate(
            kind: .rules,
            signatures: ["游戏规则", "玩法规则", "布局规则", "吃子规则", "行走路线"],
            closeKeywords: ["关闭", "我知道了", "知道了", "取消"],
            closeAnchor: nil,
            pauseReason: nil
        ),
        PopupTemplate(
            kind: .announcement,
            signatures: ["系统公告", "更新公告", "活动公告", "公告内容"],
            closeKeywords: ["关闭", "我知道了", "知道了", "取消"],
            closeAnchor: nil,
            pauseReason: nil
        ),
        PopupTemplate(
            kind: .disconnect,
            signatures: ["重新连接", "网络异常", "连接失败", "断线重连", "连接已断开"],
            closeKeywords: ["重新连接", "关闭", "取消"],
            closeAnchor: nil,
            pauseReason: nil
        ),
        PopupTemplate(
            kind: .realName,
            signatures: ["实名认证", "防沉迷", "身份验证"],
            closeKeywords: [],
            closeAnchor: nil,
            pauseReason: "实名/防沉迷提示需要人工处理"
        ),
        PopupTemplate(
            kind: .ad,
            signatures: ["观看广告", "看广告", "广告奖励"],
            closeKeywords: [],
            closeAnchor: nil,
            pauseReason: "广告弹窗按设计暂停，不自动观看/跳过"
        ),
        PopupTemplate(
            kind: .update,
            signatures: ["版本更新", "更新内容", "立即更新"],
            closeKeywords: [],
            closeAnchor: nil,
            pauseReason: "版本更新弹窗不自动处理"
        ),
    ]

    static func template(for kind: PopupKind) -> PopupTemplate? {
        templates.first { $0.kind == kind }
    }
}

/// 弹窗关闭锚点键。校准文件里可以用同名 key 覆盖模板内置锚点。
enum PopupAnchor: String, CaseIterable, Sendable {
    case signInClose = "popup.close.signIn"
    case taskClose = "popup.close.task"
    case profileClose = "popup.close.profile"
    /// 规则/公告等通用关闭位置；没有校准时不启用，避免盲点。
    case genericClose = "popup.close"
}

/// 模板内置关闭锚点（归一化窗口坐标，左上原点）。
///
/// 数值来自 2026-10-28 实测截图：签到/任务弹层右上角 X、个人信息弹层左上角 X。
/// 用户可在 `calibration.json` 的 `buttons` 里用同名 key 覆盖。
enum PopupAnchorDefaults {
    static func rect(forKey key: String) -> CGRect? {
        guard let anchor = PopupAnchor(rawValue: key) else { return nil }
        switch anchor {
        case .signInClose:
            return CGRect(x: 0.795, y: 0.235, width: 0.080, height: 0.075)
        case .taskClose:
            return CGRect(x: 0.798, y: 0.273, width: 0.080, height: 0.077)
        case .profileClose:
            return CGRect(x: 0.230, y: 0.200, width: 0.071, height: 0.076)
        case .genericClose:
            return nil
        }
    }
}

/// 纯逻辑弹窗解析器：只依赖 OCR 文本，不碰窗口/点击，便于单测。
enum PopupResolver {
    static func resolve(hits: [OCRText]) -> PopupResolution {
        let text = hits.map(\.text).joined(separator: " ")

        for template in PopupCatalog.templates {
            let matched = template.signatures.filter { text.contains($0) }
            guard !matched.isEmpty else { continue }

            if let reason = template.pauseReason {
                return .known(kind: template.kind, action: .pause(reason), matched: matched)
            }

            if let keyword = firstCloseKeyword(template.closeKeywords, in: hits) {
                // 退出确认只允许「取消」；这里由 closeKeywords 保证不会出现「确定」。
                return .known(
                    kind: template.kind,
                    action: .close(.keyword(keyword)),
                    matched: matched
                )
            }

            if let anchor = template.closeAnchor {
                return .known(
                    kind: template.kind,
                    action: .close(.anchor(anchor)),
                    matched: matched
                )
            }

            return .known(
                kind: template.kind,
                action: .pause("未找到关闭按钮或校准锚点"),
                matched: matched
            )
        }

        return .unknown
    }

    private static func firstCloseKeyword(_ keywords: [String], in hits: [OCRText]) -> String? {
        for keyword in keywords where hits.contains(where: { $0.text.contains(keyword) }) {
            return keyword
        }
        return nil
    }
}

/// 每次进入流程的 3 轮关闭预算。
struct PopupRoundTracker: Equatable, Sendable {
    let maxRounds: Int
    private(set) var rounds = 0

    init(maxRounds: Int = PopupCatalog.maxCloseRounds) {
        self.maxRounds = max(0, maxRounds)
    }

    var remaining: Int {
        max(0, maxRounds - rounds)
    }

    /// 申请一轮关闭预算；返回 false 表示已经达到上限。
    mutating func beginRound() -> Bool {
        guard rounds < maxRounds else { return false }
        rounds += 1
        return true
    }

    mutating func reset() {
        rounds = 0
    }
}
