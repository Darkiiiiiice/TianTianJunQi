import CoreGraphics
import Foundation
import Observation

/// 校准状态：用于设置页提示与进入流程的前置检查。
enum CalibrationStatus: Equatable, Sendable {
    case none
    case ready
    /// 可继续用旧锚点，但建议重新校准（皮肤/窗口比例变化）。
    case stale(String)

    var label: String {
        switch self {
        case .none: "未校准"
        case .ready: "已校准"
        case .stale(let reason): "已校准 · \(reason)"
        }
    }
}

/// 本机校准数据的读写与状态判定（M1-1）。
/// 所有锚点都是归一化坐标，与 OCR/点击共用同一坐标系：
/// 相对抓帧裁剪后的窗口内容区（0..1，左上原点）。
@MainActor
@Observable
final class CalibrationStore {
    private(set) var calibration: Calibration?
    private(set) var lastError: String?
    private(set) var savedAt: Date?

    private let storage = StorageKit()

    init() {
        reload()
    }

    var calibrationURL: URL { storage.calibrationURL }

    func reload() {
        do {
            calibration = try storage.loadCalibration()
            lastError = nil
        } catch {
            calibration = nil
            lastError = "读取校准失败：\(error.localizedDescription)"
        }
    }

    /// 保存完整校准。`venue` 存进 buttons（与设计文档的按钮锚点共用字典）。
    @discardableResult
    func save(
        canvasROI: CGRect,
        boardCorners: [CGPoint],
        boardColumnCenters: [CGFloat]? = nil,
        boardRowCenters: [CGFloat]? = nil,
        modeEntry: CGRect,
        venue: CGRect,
        windowSize: CGSize,
        theme: String
    ) -> Bool {
        var buttons = calibration?.buttons ?? [:]
        buttons["venue"] = venue
        let value = Calibration(
            windowSize: windowSize,
            canvasROI: canvasROI,
            boardCorners: boardCorners,
            boardColumnCenters: boardColumnCenters,
            boardRowCenters: boardRowCenters,
            modeEntry: modeEntry,
            buttons: buttons,
            templates: calibration?.templates ?? [:],
            theme: theme
        )

        do {
            try StorageKit().saveCalibration(value)
            calibration = value
            savedAt = Date()
            lastError = nil
            return true
        } catch {
            lastError = "保存校准失败：\(error.localizedDescription)"
            return false
        }
    }

    func clear() {
        do {
            try storage.deleteCalibration()
            calibration = nil
            savedAt = nil
            lastError = nil
        } catch {
            lastError = "清除校准失败：\(error.localizedDescription)"
        }
    }

    /// 当前校准是否还能直接用；窗口比例或皮肤变化时给出 stale 提示。
    func status(currentWindowSize: CGSize?, theme: String) -> CalibrationStatus {
        guard let cal = calibration else { return .none }
        if cal.boardCorners.count != 4 {
            return .stale("棋盘四角不完整")
        }
        if cal.buttons["venue"] == nil {
            return .stale("缺少场次按钮锚点")
        }
        if cal.theme != theme {
            return .stale("皮肤已变化（\(cal.theme) → \(theme)）")
        }
        if let currentWindowSize,
           cal.windowSize.width > 0, cal.windowSize.height > 0,
           currentWindowSize.width > 0, currentWindowSize.height > 0 {
            let savedAspect = cal.windowSize.width / cal.windowSize.height
            let currentAspect = currentWindowSize.width / currentWindowSize.height
            if abs(currentAspect - savedAspect) / savedAspect > 0.08 {
                return .stale("窗口宽高比变化较大")
            }
        }
        return .ready
    }
}
