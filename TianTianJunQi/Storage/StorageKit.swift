import CoreGraphics
import Foundation

/// 存储层（设计文档 §5）：Application Support 目录布局 + `game-profile.json` / `calibration.json` 读写。
/// 数据集、模型、日志全部放 Application Support，不进 App Bundle；校准文件只存本机，不入库。
struct StorageKit {
    /// `~/Library/Application Support/TianTianJunqiAI/`
    let rootURL: URL

    init(rootURL: URL = StorageKit.defaultRootURL) {
        self.rootURL = rootURL
    }

    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TianTianJunqiAI", isDirectory: true)
    }

    // MARK: 目录布局

    var gameProfileURL: URL { rootURL.appendingPathComponent("game-profile.json") }
    var calibrationURL: URL { rootURL.appendingPathComponent("calibration.json") }
    var episodesURL: URL { rootURL.appendingPathComponent("episodes", isDirectory: true) }
    var datasetsURL: URL { rootURL.appendingPathComponent("datasets", isDirectory: true) }
    var modelsURL: URL { rootURL.appendingPathComponent("models", isDirectory: true) }
    var perceptionURL: URL { rootURL.appendingPathComponent("perception", isDirectory: true) }
    /// 棋盘样本：整帧 + 每个格子的透视图 + meta.json（M1-3/M2-7）。
    var samplesURL: URL { perceptionURL.appendingPathComponent("samples", isDirectory: true) }
    /// 屏幕分类样本：窗口内容区整帧 + 人工标签（M1-7）。
    var screenSamplesURL: URL {
        perceptionURL.appendingPathComponent("screen-samples", isDirectory: true)
    }
    /// 未知/无法处理弹窗的现场截图与 OCR（M1-8）。
    var popupsURL: URL {
        perceptionURL.appendingPathComponent("popups", isDirectory: true)
    }
    var simURL: URL { rootURL.appendingPathComponent("sim", isDirectory: true) }
    var logsURL: URL { rootURL.appendingPathComponent("logs", isDirectory: true) }

    /// 建根目录与一级子目录（幂等）。
    func ensureLayout() throws {
        let fm = FileManager.default
        for url in [rootURL, episodesURL, datasetsURL, modelsURL, perceptionURL, simURL, logsURL] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: screenSamplesURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: popupsURL, withIntermediateDirectories: true)
    }

    // MARK: game-profile.json

    func loadGameProfile() throws -> GameProfile? {
        try load(GameProfile.self, from: gameProfileURL)
    }

    func saveGameProfile(_ profile: GameProfile) throws {
        try save(profile, to: gameProfileURL)
    }

    /// 读取配置；文件不存在时写入当前实测默认值（P0-1～P0-4 回填），保证首次启动即有配置。
    func loadOrCreateGameProfile() throws -> GameProfile {
        if let profile = try loadGameProfile() { return profile }
        let profile = GameProfile.tianTianJunQi
        try saveGameProfile(profile)
        return profile
    }

    // MARK: calibration.json

    func loadCalibration() throws -> Calibration? {
        try load(Calibration.self, from: calibrationURL)
    }

    func saveCalibration(_ calibration: Calibration) throws {
        try save(calibration, to: calibrationURL)
    }

    func deleteCalibration() throws {
        guard FileManager.default.fileExists(atPath: calibrationURL.path) else { return }
        try FileManager.default.removeItem(at: calibrationURL)
    }

    // MARK: JSON 读写

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureLayout()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

// MARK: - game-profile.json

/// 游戏配置（设计文档 §5 GameProfile；字段值来自 `shared/game-profiles/tiantian-junqi.yaml` 实测回填）。
struct GameProfile: Codable, Equatable, Sendable {
    var game: String
    var mode: String
    var window: WindowSpec
    var board: BoardSpec
    var opponent: OpponentSpec

    /// 当前游戏的实测默认值（P0-1～P0-4）。
    static let tianTianJunQi = GameProfile(
        game: "天天军棋",
        mode: "翻翻棋",
        window: WindowSpec(
            ownerBundleIDs: ["com.tencent.xinWeChat", "com.tencent.flue.WeChatAppEx"],
            titleContains: ["天天军棋"],
            minSize: CGSize(width: 240, height: 180),
            canvasROI: CGRect(x: 0.0, y: 0.07, width: 1.0, height: 0.93)
        ),
        board: BoardSpec(
            rows: 5,
            cols: 12,
            piecesPerSide: 25,
            theme: "default",
            // 2026-10-27 实测：7 个会话首帧都是 50 枚棋子 + 10 个固定绿色圆圈空站点；
            // 站点开局为空，但后续可被棋子占据（不是永久空格）。
            stationCells: [14, 16, 19, 21, 27, 32, 38, 40, 43, 45]
        ),
        opponent: OpponentSpec(
            style: "quickMatch",
            venue: "新手场",
            autoContinueHuman: true,
            ticketCost: 50,
            matchTimeout: 120
        )
    )
}

struct WindowSpec: Codable, Equatable, Sendable {
    /// P0-1 实测：小游戏窗口由主微信进程持有，WeChatAppEx 只渲染；两者都进候选池。
    var ownerBundleIDs: [String]
    var titleContains: [String]
    var minSize: CGSize
    /// 画布内容区（归一化 0..1，相对整窗），排除小程序标题栏。
    var canvasROI: CGRect
}

struct BoardSpec: Codable, Equatable, Sendable {
    var rows: Int
    var cols: Int
    /// 棋盘上每方棋子数（2026-10-27 实测：25，不是 30）。
    var piecesPerSide: Int
    /// 皮肤/主题：校准失效判定用。
    var theme: String
    /// 开局固定空站点（行优先索引）。可被棋子占据，不是永久空格。
    var stationCells: [Int]?
}

struct OpponentSpec: Codable, Equatable, Sendable {
    /// "quickMatch"（P0-4 实测无单机/练习，只能真人匹配）。
    var style: String
    var venue: String
    /// 用户 2026-10-23 显式选择：允许自动再来一局。
    var autoContinueHuman: Bool
    var ticketCost: Int
    /// 匹配等待上限（秒），超时暂停。
    var matchTimeout: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case style = "default"
        case venue, autoContinueHuman, ticketCost, matchTimeout
    }
}

// MARK: - calibration.json

/// 校准数据（设计文档 §5 Calibration）：只存本机，不入库。
/// 所有锚点都是归一化坐标（0..1，左上原点），相对抓帧裁剪后的窗口内容区，
/// 与 OCR/点击共用同一坐标系。
struct Calibration: Codable, Equatable, Sendable {
    /// 校准时窗口的 point 尺寸；仅用于提示比例变化，不参与坐标换算。
    var windowSize: CGSize
    /// 游戏画布区域。
    var canvasROI: CGRect
    /// 棋盘四角（左上 → 右上 → 右下 → 左下）。
    var boardCorners: [CGPoint]
    /// 每列中心线（归一化图像 x，数量 = 列数）。旧校准没有这一项，按均分处理。
    var boardColumnCenters: [CGFloat]?
    /// 每行中心线（归一化图像 y，数量 = 行数）。
    var boardRowCenters: [CGFloat]?
    /// “翻翻棋”入口。
    var modeEntry: CGRect
    /// 开始/再来一局/关闭/场次等按钮锚点。
    var buttons: [String: CGRect]
    var templates: [String: URL]
    /// 与 `GameProfile.board.theme` 不一致时要求重新校准。
    var theme: String
}
