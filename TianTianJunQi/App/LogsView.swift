import SwiftUI

/// 日志页：应用状态迁移记录；调试选择器用于骨架阶段手动驱动状态机。
struct LogsView: View {
    let store: AppStateStore

    @State private var debugSelection: AppState = .idle

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("调试：切换状态", selection: $debugSelection) {
                    ForEach(AppState.allCases, id: \.self) { state in
                        Text(state.label).tag(state)
                    }
                }
                .labelsHidden()
                .frame(width: 180)

                Spacer()

                Text("共 \(store.changes.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Divider()

            Table(store.changes) {
                TableColumn("时间") { entry in
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                }
                .width(min: 90, ideal: 110)

                TableColumn("迁移") { entry in
                    Text("\(entry.from.label) → \(entry.to.label)")
                }
                .width(min: 150, ideal: 190)

                TableColumn("原因") { entry in
                    Text(entry.reason)
                }
            }
        }
        .onChange(of: debugSelection) { _, newState in
            store.transition(to: newState, reason: "手动切换（调试）")
        }
    }
}
