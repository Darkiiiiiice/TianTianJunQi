import Foundation

/// 翻翻棋棋子目录（P0-3 实测 12 类；顺序从高到低，地雷/炸弹/军旗单列）。
/// 分类器与标注 UI 共用，避免在多个地方硬编码中文名称。
enum PieceCatalog {
    static let ranks: [String] = [
        "司令", "军长", "师长", "旅长", "团长", "营长",
        "连长", "排长", "工兵",
    ]
    static let specials: [String] = ["地雷", "炸弹", "军旗"]
    static let all: [String] = ranks + specials

    /// Core ML 分类器输出 ID（训练端 `wgai.dataset.PIECE_IDS`）→ 中文名。
    /// 客户端只依赖这份映射，避免把英文 ID 直接写进 `CellObservation.piece`。
    static let classifierIDs: [String: String] = [
        "commander": "司令",
        "army_commander": "军长",
        "division_commander": "师长",
        "brigade_commander": "旅长",
        "regiment_commander": "团长",
        "battalion_commander": "营长",
        "company_commander": "连长",
        "platoon_commander": "排长",
        "engineer": "工兵",
        "mine": "地雷",
        "bomb": "炸弹",
        "flag": "军旗",
    ]

    static func isValid(_ name: String) -> Bool {
        all.contains(name)
    }

    static func name(forClassifierID id: String) -> String? {
        classifierIDs[id]
    }

    /// 中文名 → 分类器 ID（GameState 序列化用，与训练端 `PIECE_IDS` 对齐）。
    static func classifierID(forName name: String) -> String? {
        classifierIDs.first { $0.value == name }?.key
    }
}
