import SwiftUI

@MainActor struct DownloadPicker: View {
    @ObservedObject var model: DetailModel
    @EnvironmentObject private var downloads: DownloadCenter
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var from = "1"
    @State private var to = ""
    let finished: (Int) -> Void
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.work.title).font(.headline)
                    Text("当前线路 · 已加载 \(model.episodes.count) / \(model.total) 集")
                    Text("只加入下载任务，不会启动播放器或写入观看记录。默认仅 Wi-Fi 下载。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("选择剧集") {
                    HStack {
                        Button("全选已加载") { selected = Set(model.episodes.filter { $0.unsupportedReason == nil }.map(\.key)) }
                        Spacer()
                        Button("取消选择") { selected = [] }
                    }.buttonStyle(.borderless)
                    HStack {
                        TextField("起始序号", text: $from).keyboardType(.numberPad)
                        Text("至")
                        TextField("结束序号", text: $to).keyboardType(.numberPad)
                        Button("选范围") {
                            let start = max(1, Int(from) ?? 1), end = min(model.episodes.count, Int(to) ?? model.episodes.count)
                            selected = Set(model.episodes.enumerated().filter { (start...max(start, end)).contains($0.offset + 1) && $0.offset + 1 <= end && $0.element.unsupportedReason == nil }.map { $0.element.key })
                        }
                    }.buttonStyle(.borderless)
                    ForEach(model.episodes) { episode in
                        Button {
                            if !selected.insert(episode.key).inserted { selected.remove(episode.key) }
                        } label: {
                            HStack { Text(episode.name + (episode.unsupportedReason == nil ? "" : " · 暂不支持")); Spacer(); Image(systemName: selected.contains(episode.key) ? "checkmark.circle.fill" : "circle") }
                        }.disabled(episode.unsupportedReason != nil).accessibilityIdentifier("choose_\(episode.key)")
                    }
                    if model.episodes.count < model.total {
                        Button("加载更多剧集") { Task { await model.loadEpisodes(reset: false) } }.disabled(model.loadingEpisodes)
                    }
                    if let error = model.episodeError { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("只下载").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("开始下载") {
                        let choices = model.episodes.filter { selected.contains($0.key) }.compactMap(model.selection)
                        let count = downloads.enqueue(choices); finished(count); dismiss()
                    }.disabled(selected.isEmpty).accessibilityIdentifier("confirm_download")
                }
            }
        }
    }
}
@MainActor struct DownloadsScreen: View {
    let service: any CatalogService
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var playing: DownloadEntry?
    @State private var deleting: DownloadEntry?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if let storageError = downloads.storageError { Text(storageError).foregroundStyle(.red) }
                ForEach(downloads.entries.sorted { $0.createdAt > $1.createdAt }) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.selection.work.title).font(.headline)
                        Text(entry.selection.work.sourceName + " · " + entry.selection.episode.name).font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Text(entry.state.label).accessibilityIdentifier("download_state_\(entry.selection.episode.key)")
                            Spacer()
                            if entry.state != .complete { Text(entry.progress, format: .percent.precision(.fractionLength(0))) }
                        }.font(.caption).foregroundStyle(.secondary)
                        if entry.state != .complete { ProgressView(value: entry.progress) }
                        if entry.bytes > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = entry.error { Text(error).font(.caption).foregroundStyle(.red) }
                        HStack(spacing: 24) {
                            if entry.state == .complete {
                                Button("离线播放", systemImage: "play.fill") { playing = entry }
                            } else if entry.state == .paused || entry.state == .failed {
                                Button(entry.state == .paused ? "继续" : "重试", systemImage: "arrow.clockwise") { downloads.resume(entry.id) }
                            } else {
                                Button("暂停", systemImage: "pause") { downloads.pause(entry.id) }
                            }
                            Spacer()
                            Button("删除", systemImage: "trash", role: .destructive) { deleting = entry }
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 8)
                }
                if !downloads.entries.isEmpty {
                    Text("默认仅 Wi-Fi 下载。离线文件不会随搜索记录清除；系统可能因空间不足移除 HLS 媒体包。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .overlay { if downloads.entries.isEmpty && downloads.storageError == nil { ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle", description: Text("在影片详情选择“只下载”，可批量选择剧集。")) } }
            .navigationTitle("下载")
            .confirmationDialog("删除任务和已下载内容？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("确认删除", role: .destructive) {
                    if let entry = deleting { do { try downloads.remove(entry.id) } catch { self.error = error.localizedDescription } }
                    deleting = nil
                }
            }
            .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
            .fullScreenCover(item: $playing) { entry in
                PlaybackScreen(selection: entry.selection, service: service, offlineID: entry.id)
            }
        }
    }
}
