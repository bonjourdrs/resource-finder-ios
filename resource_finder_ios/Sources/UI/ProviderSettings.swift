import SwiftUI

@MainActor struct ProviderSettingsScreen: View {
    let service: MultiCatalogService
    @ObservedObject private var access: ProviderAccessStore
    @State private var keyword = "流浪地球"
    @State private var checking = Set<String>()
    init(service: MultiCatalogService) { self.service = service; access = service.access }
    var body: some View {
        Form {
            Section {
                Text("已开启 \(ProviderRegistry.all.filter { access.enabled($0.id) }.count) / \(ProviderRegistry.all.count) 个影视来源")
                Text("未验证和本次失败不会自动关闭来源。开关对下一次聚合搜索生效。").font(.caption).foregroundStyle(.secondary)
                TextField("检索验证关键词", text: $keyword)
            }
            ForEach(ProviderRegistry.all) { provider in
                let observation = access.observation(provider.id)
                Section(provider.name + (provider.experimental ? " · 实验来源" : "")) {
                    Toggle("参与搜索", isOn: Binding(get: { access.enabled(provider.id) }, set: { access.setEnabled(provider.id, $0) }))
                    observationRow("目录检索", observation.catalog, catalog: true)
                    observationRow("最近媒体解析", observation.media)
                    Button(checking.contains(provider.id) ? "检索中…" : "重新检索此来源") {
                        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                        checking.insert(provider.id)
                        Task { defer { checking.remove(provider.id) }; do { try await service.probe(provider.id, query: query) } catch {} }
                    }.disabled(checking.contains(provider.id) || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section { Text("目录有响应不代表视频可播放。状态只代表最近一次请求，不代表所有影片、剧集或完整播放均通过。").font(.caption) }
        }.navigationTitle("来源设置")
    }
    private func observationRow(_ title: String, _ value: AccessObservation, catalog: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title + "：" + (catalog && value.state == .resolved ? "已响应" : value.state.label))
            if !value.detail.isEmpty { Text(value.detail).font(.caption).foregroundStyle(.secondary) }
            if let date = value.checkedAt { Text(date.formatted(date: .numeric, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
