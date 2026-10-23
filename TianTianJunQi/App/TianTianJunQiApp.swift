import SwiftUI

@main
struct TianTianJunQiApp: App {
    init() {
        guard SingleInstanceLock.acquire() else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "天天军棋 AI 已在运行"
            alert.informativeText = "同一时间只允许一个客户端控制游戏窗口和鼠标，请先退出已有实例。"
            alert.runModal()
            exit(0)
        }
    }

    var body: some Scene {
        Window("天天军棋 · 翻翻棋 AI", id: "main") {
            MainView()
                .frame(minWidth: 760, minHeight: 520)
                .onReceive(
                    NotificationCenter.default
                        .publisher(for: NSWindow.willCloseNotification)
                ) { notification in
                    guard let window = notification.object as? NSWindow,
                          window.styleMask.contains(.titled),
                          !window.styleMask.contains(.nonactivatingPanel)
                    else { return }
                    // 单窗口应用：主窗口关闭即退出，不驻留菜单栏（设计文档 §3.2）
                    DispatchQueue.main.async {
                        let titledVisible = NSApp.windows.contains {
                            $0.isVisible && $0.styleMask.contains(.titled)
                        }
                        if !titledVisible {
                            NSApp.terminate(nil)
                        }
                    }
                }
        }
        .windowResizability(.contentMinSize)
    }
}
