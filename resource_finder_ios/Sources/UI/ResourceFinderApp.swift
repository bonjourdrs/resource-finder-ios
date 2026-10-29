import SwiftUI

@main @MainActor struct ResourceFinderApp: App {
    @UIApplicationDelegateAdaptor(ResourceAppDelegate.self) private var appDelegate
    @StateObject private var downloads: DownloadCenter
    @StateObject private var watch: WatchStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: LibraryStore
    private let service: (any CatalogService)?
    private let startupError: String?
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let defaults = UserDefaults(suiteName: "com.resourcefinder.ios.uitests")!
            defaults.removePersistentDomain(forName: "com.resourcefinder.ios.uitests")
            _store = StateObject(wrappedValue: LibraryStore(defaults: defaults))
            let fixtureService = FixtureCatalogService()
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UITestDownloads")
            if !ProcessInfo.processInfo.arguments.contains("--keep-downloads") { try? FileManager.default.removeItem(at: root) }
            let center = DownloadCenter(root: root, namespace: "com.resourcefinder.ios.uitests.downloads")
            _downloads = StateObject(wrappedValue: center)
            _watch = StateObject(wrappedValue: WatchStore(defaults: defaults))
            ResourceAppDelegate.downloadCenter = center; center.configure(service: fixtureService)
            service = fixtureService; startupError = nil
            return
        }
        #endif
        _store = StateObject(wrappedValue: LibraryStore())
        _watch = StateObject(wrappedValue: WatchStore())
        _downloads = StateObject(wrappedValue: DownloadCenter.shared)
        ResourceAppDelegate.downloadCenter = DownloadCenter.shared
        service = MultiCatalogService(primary: DeferredJianpianService()); startupError = nil
        if let service { DownloadCenter.shared.configure(service: service) }
    }
    var body: some Scene {
        WindowGroup {
            if let service { RootView(service: service).environmentObject(store).environmentObject(downloads).environmentObject(watch).onChange(of: scenePhase) { _, value in if value == .active { downloads.foreground() } }.tint(Color(red: 0.05, green: 0.46, blue: 0.40)) }
            else { ContentUnavailableView("暂时无法启动", systemImage: "exclamationmark.triangle", description: Text(startupError ?? "请重新启动应用")) }
        }
    }
}
@MainActor struct RootView: View {
    let service: any CatalogService
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var watch: WatchStore
    @State private var watchPlayback: MediaSelection?
    @State private var selectedTab = 0
    @State private var historyQuery: String?
    @State private var confirmClear = false
    var body: some View {
        TabView(selection: $selectedTab) {
            SearchScreen(service: service, historyQuery: $historyQuery)
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(0)
            NavigationStack {
                List(store.favorites, id: \.sourceKey) { work in
                    NavigationLink { DetailScreen(work: work, service: service) } label: { WorkRow(work: work) }
                }
                .overlay { if store.favorites.isEmpty { ContentUnavailableView("还没有收藏", systemImage: "star", description: Text("在影片详情页点星标，方便下次找到。")) } }
                .navigationTitle("收藏")
            }.tabItem { Label("收藏", systemImage: "star") }.tag(1)
            DownloadsScreen(service: service).tabItem { Label("下载", systemImage: "arrow.down.circle") }.tag(2)
            NavigationStack {
                List {
                    if !watch.records.isEmpty {
                        Section("继续观看") {
                            ForEach(watch.records) { record in
                                Button { watchPlayback = record.selection } label: {
                                    VStack(alignment: .leading) { Text(record.selection.work.title); Text(record.selection.episode.name + " · " + String(Int(record.position)) + " 秒").font(.caption).foregroundStyle(.secondary) }
                                }.swipeActions { Button("删除观看", role: .destructive) { watch.remove(record.id) } }
                            }
                        }
                    }
                    Section("搜索记录") { ForEach(store.searches, id: \.self) { query in
                        Button { historyQuery = query; selectedTab = 0 } label: { Label(query, systemImage: "clock") }.foregroundStyle(.primary)
                    }.onDelete(perform: store.removeSearches) }
                }
                .overlay { if store.searches.isEmpty && watch.records.isEmpty { ContentUnavailableView("暂无搜索记录", systemImage: "clock") } }
                .navigationTitle("搜索记录")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("清空记录", role: .destructive) { confirmClear = true }.disabled(store.searches.isEmpty) } }
                .confirmationDialog("清空全部搜索记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("确认清空", role: .destructive) { store.clearSearches() }
                }
            }.tabItem { Label("历史", systemImage: "clock") }.tag(3)
            if let multi = service as? MultiCatalogService {
                NavigationStack { ProviderSettingsScreen(service: multi) }.tabItem { Label("设置", systemImage: "gearshape") }.tag(4)
            }
        }
        .fullScreenCover(item: $watchPlayback) { selection in PlaybackScreen(selection: selection, service: service) }
    }
}
@MainActor struct SearchScreen: View {
    let service: any CatalogService
    @Binding var historyQuery: String?
    @StateObject private var model: SearchModel
    @EnvironmentObject private var store: LibraryStore
    @FocusState private var searchFocused: Bool
    init(service: any CatalogService, historyQuery: Binding<String?>) {
        self.service = service; _historyQuery = historyQuery
        _model = StateObject(wrappedValue: SearchModel(service: service))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索影片、剧集", text: $model.query).submitLabel(.search)
                            .focused($searchFocused)
                            .autocorrectionDisabled().accessibilityIdentifier("search_field")
                            .onSubmit { searchFocused = false; model.search(store: store) }
                    }.padding(12).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    Button("搜索") { searchFocused = false; model.search(store: store) }.fontWeight(.semibold).accessibilityIdentifier("search_submit")
                }.padding(.horizontal, 20).padding(.vertical, 12)
                if let error = model.error {
                    VStack(spacing: 8) { Text(error).foregroundStyle(.red); Button("重试") { model.loadMore() } }.padding()
                }
                if !model.results.isEmpty {
                    List {
                        Section {
                            ForEach(model.results, id: \.sourceKey) { work in
                                NavigationLink { DetailScreen(work: work, service: service) } label: { WorkRow(work: work) }
                                    .accessibilityIdentifier("work_\(work.id)")
                            }
                        } header: { Text("搜索结果 · 多来源") }
                        if model.hasMore { Button("加载更多") { model.loadMore() }.disabled(model.loading) }
                        if model.loading { HStack { Spacer(); ProgressView(); Spacer() } }
                    }.listStyle(.insetGrouped).scrollDismissesKeyboard(.interactively)
                } else if model.loading { Spacer(); ProgressView("正在搜索"); Spacer() }
                else if model.searched && model.error == nil {
                    ContentUnavailableView.search(text: model.query)
                } else {
                    ContentUnavailableView("找一部想看的影片", systemImage: "play.rectangle", description: Text("搜索影片，选择线路和剧集后播放。"))
                }
            }
            .background(Color(.systemGroupedBackground)).navigationTitle("资源搜索")
            .onChange(of: historyQuery) { _, value in
                if let value { searchFocused = false; model.query = value; model.search(store: store); historyQuery = nil }
            }
            .onDisappear { searchFocused = false }
        }
    }
}
struct WorkRow: View {
    let work: VideoWork
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: work.posterURL.flatMap(URL.init(string:))) { image in image.resizable().scaledToFill() } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill)).overlay { Image(systemName: "film").foregroundStyle(.secondary) }
            }.frame(width: 66, height: 92).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 7) {
                Text(work.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text([work.year.map(String.init), work.kind, work.remarks].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(work.sourceName + (ProviderRegistry.config(work.providerID)?.experimental == true ? " · 实验来源" : "")).font(.caption).foregroundStyle(.secondary)
                Text(work.displaySummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.padding(.vertical, 4)
        }.padding(.vertical, 6)
    }
}
@MainActor struct DetailScreen: View {
    let service: any CatalogService
    @StateObject private var model: DetailModel
    @EnvironmentObject private var store: LibraryStore
    @State private var playback: MediaSelection?
    @State private var showDownloads = false
    @State private var downloadMessage: String?
    init(work: VideoWork, service: any CatalogService) {
        self.service = service; _model = StateObject(wrappedValue: DetailModel(work: work, service: service))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkRow(work: model.work)
                if model.loading { ProgressView("正在加载详情") }
                if let error = model.error { Text(error).foregroundStyle(.red); Button("重新加载") { Task { await model.load() } } }
                if !model.loading && model.error == nil {
                    VStack(alignment: .leading, spacing: 10) { Text("简介").font(.headline); Text(model.work.displaySummary).font(.subheadline).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("播放线路").font(.headline); Spacer(); Button("刷新目录") { Task { await model.load(refresh: true) } } }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(model.lines) { line in
                                    Button { model.selectedLine = line.key } label: {
                                        Label(line.name + " · " + model.lineStatus(line), systemImage: line.available ? (model.selectedLine == line.key ? "checkmark.circle.fill" : "circle") : "lock")
                                            .padding(.horizontal, 14).padding(.vertical, 11)
                                            .background(model.selectedLine == line.key ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground), in: Capsule())
                                    }.buttonStyle(.plain).disabled(!line.available).accessibilityIdentifier("line_\(line.key)")
                                }
                            }
                        }
                        if model.selectedLine == nil { Text("暂无可用的访客播放线路").foregroundStyle(.secondary) }
                        if let line = model.lines.first(where: { $0.key == model.selectedLine }), let reason = line.unsupportedReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        if let key = model.selectedLine, !model.episodes.isEmpty {
                            Button(model.checkingLine == nil ? "检查 / 重试本线路首集" : "正在检查…") { Task { await model.checkLine() } }.disabled(model.checkingLine != nil)
                            if let check = model.lineChecks[key] { Text(check.state.label + "：" + check.detail).font(.caption) }
                            Text("仅解析首集地址，不下载视频；其他集可能不同。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("只下载", systemImage: "arrow.down.circle") { showDownloads = true }.buttonStyle(.borderedProminent).disabled(model.episodes.isEmpty).accessibilityIdentifier("download_only")
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Text("选择剧集").font(.headline); Spacer(); Text("\(model.episodes.count) / \(model.total)").font(.caption).foregroundStyle(.secondary) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: 12) {
                            ForEach(model.episodes) { episode in
                                Button { playback = model.selection(episode) } label: {
                                    Text(episode.name + (episode.unsupportedReason == nil ? "" : " · 暂不支持")).font(.subheadline).lineLimit(2).frame(maxWidth: .infinity, minHeight: 44)
                                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                                }.disabled(episode.unsupportedReason != nil).accessibilityIdentifier("episode_\(episode.key)")
                            }
                        }
                        if model.loadingEpisodes { ProgressView("正在加载剧集") }
                        if let error = model.episodeError { Text(error).foregroundStyle(.red); Button("重试选集") { Task { await model.loadEpisodes(reset: false) } } }
                        if model.episodes.count < model.total { Button("加载更多剧集") { Task { await model.loadEpisodes(reset: false) } }.disabled(model.loadingEpisodes) }
                    }
                }
            }.padding(20)
        }
        .background(Color(.systemGroupedBackground)).navigationTitle("影片详情").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { store.toggleFavorite(model.work) } label: { Image(systemName: store.isFavorite(model.work) ? "star.fill" : "star") }
                .accessibilityLabel(store.isFavorite(model.work) ? "取消收藏" : "收藏影片")
        } }
        .task { await model.load() }
        .task(id: model.selectedLine) { await model.loadEpisodes(reset: true) }
        .sheet(isPresented: $showDownloads) { DownloadPicker(model: model) { count in downloadMessage = count > 0 ? "已加入 \(count) 个下载任务" : "所选剧集已在下载列表中" } }
        .alert("下载任务", isPresented: Binding(get: { downloadMessage != nil }, set: { if !$0 { downloadMessage = nil } })) { Button("好") { downloadMessage = nil } } message: { Text(downloadMessage ?? "") }
        .fullScreenCover(item: $playback) { selection in PlaybackScreen(selection: selection, service: service, queue: model.episodes, episodeTotal: model.total) }
    }
}
