import CoreImage
import CoreVideo
import SwiftUI

/// 概览页：运行状态摘要 + 操作按钮 + 实时画面（M0-5 最小观察器，M0-11 升级为竖屏克隆）。
struct OverviewView: View {
    let store: AppStateStore
    let permissions: PermissionStore
    let windows: WindowMonitor
    let capture: CaptureService

    @State private var ciContext = CIContext()

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 24) {
                statusSection
                actionSection
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            liveSection
        }
        .padding()
    }

    private var statusSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("运行状态").foregroundStyle(.secondary)
                Text(store.state.label).font(.title3.bold())
            }
            GridRow {
                Text("游戏窗口").foregroundStyle(.secondary)
                windowStatusText
            }
            GridRow {
                Text("主界面").foregroundStyle(.secondary)
                Text("未识别（M0-6 接入）").foregroundStyle(.secondary)
            }
            GridRow {
                Text("模式 / 对手").foregroundStyle(.secondary)
                Text("翻翻棋 · 人机练习（占位）")
            }
            GridRow {
                Text("模型").foregroundStyle(.secondary)
                Text("无（M3-4 接入）").foregroundStyle(.secondary)
            }
            GridRow {
                Text("权限").foregroundStyle(.secondary)
                if permissions.allGranted {
                    Text("已就绪（\(permissions.grantedCount)/\(PermissionKind.allCases.count)）")
                        .foregroundStyle(.green)
                } else {
                    Text("缺 \(permissions.missing.map(\.label).joined(separator: "、"))")
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var windowStatusText: Text {
        if !permissions.allGranted {
            return Text("待权限就绪").foregroundStyle(.secondary)
        }
        if !windows.isWeChatRunning {
            return Text("微信未运行").foregroundStyle(.orange)
        }
        if windows.candidates.isEmpty {
            return Text("未找到游戏窗口").foregroundStyle(.orange)
        }
        return Text("已检测 · \(windows.candidates.count) 个候选").foregroundStyle(.green)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("进入翻翻棋") {}
                Button("自动对局") {}
                Button("暂停") {}
                Button("急停", role: .destructive) {}
            }
            .buttonStyle(.bordered)
            .disabled(true)

            Text("按钮将在 ModeEntry/InputInjector 接入后启用（M0-7/M0-8）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 实时画面：读取 latestFrame，@Observable 驱动按帧刷新。
    private var liveSection: some View {
        VStack(spacing: 8) {
            Group {
                if let frame = capture.latestFrame, let image = frameImage(frame) {
                    Image(decorative: image, scale: frame.scale, orientation: .up)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.secondary)
                                Text("游戏画面预览")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            }
            .frame(width: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let error = capture.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: 240)
            } else {
                Text(capture.isCapturing ? "实时画面 · 15fps（M0-5 观察器）" : "等待游戏窗口…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func frameImage(_ frame: CapturedFrame) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }
}
