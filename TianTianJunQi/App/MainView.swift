import SwiftUI

/// 单窗口主界面：概览 / 训练 / 日志 / 设置（设计文档 §3.2）。
struct MainView: View {
    @State private var store = AppStateStore()
    @State private var selection: Page = .overview

    enum Page: Hashable {
        case overview
        case training
        case logs
        case settings
    }

    var body: some View {
        TabView(selection: $selection) {
            OverviewView(store: store)
                .tabItem { Label("概览", systemImage: "gauge.with.needle") }
                .tag(Page.overview)

            TrainingView()
                .tabItem { Label("训练", systemImage: "brain.head.profile") }
                .tag(Page.training)

            LogsView(store: store)
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }
                .tag(Page.logs)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Page.settings)
        }
    }
}
