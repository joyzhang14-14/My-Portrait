import SwiftUI

/// Memories 的 Text 视图设置。与 Neural Graph 设置页一样从 Memories
/// 侧栏进入，不在全局 Settings 里重复出现。
struct MemoryTextSettingsView: View {
    @State private var config = ConfigStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard(title: "Memory") {
                    SettingsRow("Memory sort order",
                                description: "How entries in Memories are ordered — and the events inside each folder. Weight ranks by importance; Created and Last occurrence sort newest first.",
                                icon: "arrow.up.arrow.down") {
                        Picker("", selection: config.binding(\.display.memorySortOrder)) {
                            ForEach(MemorySortOrder.allCases) { order in
                                Text(order.label).tag(order.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SidebarBackdrop().ignoresSafeArea())
    }
}
