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

    static func isValid(_ name: String) -> Bool {
        all.contains(name)
    }
}
