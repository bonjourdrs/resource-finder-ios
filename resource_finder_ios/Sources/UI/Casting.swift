import AVKit
import SwiftUI

@MainActor final class CastModel: ObservableObject {
    static let shared = CastModel()
    @Published private(set) var devices: [TVDevice] = []
    @Published private(set) var searching = false
    @Published private(set) var busy = false
    @Published private(set) var device: TVDevice?
    @Published private(set) var status = "未连接"
    @Published private(set) var error: String?
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var canSeek = true
    @Published private(set) var canVolume = true
    @Published private(set) var relaying = false
    private let client: DLNAClient
    private var relay: MediaRelay?
    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var generation = UUID()
    private var selection: MediaSelection?
    private var service: (any CatalogService)?
    private var watch: WatchStore?
    private var downloads: DownloadCenter?
    private var offlineID: String?
    private var export: AVAssetExportSession?
    private var exportURL: URL?
    init(client: DLNAClient? = nil) { self.client = client ?? DLNAClient() }
    func search() {
        searchTask?.cancel(); searching = true; error = nil
        searchTask = Task {
            defer { searching = false }
            do { devices = try await client.discover(); if devices.isEmpty { error = DLNAError.discovery.localizedDescription } }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func add(_ text: String) async {
        do {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw DLNAError.invalidDevice }
            let tv = try await client.device(at: url)
            devices.removeAll { $0.id == tv.id }; devices.append(tv); error = nil
        } catch { self.error = error.localizedDescription }
    }
    func connect(_ tv: TVDevice, selection: MediaSelection, service: any CatalogService, downloads: DownloadCenter, watch: WatchStore, offlineID: String?, position: Double, forceRelay: Bool, pauseLocal: @escaping () -> Void, userInitiated: Bool = true) {
        commandTask?.cancel(); pollTask?.cancel(); generation = UUID(); let token = generation
        busy = true; error = nil; status = "正在连接电视"; canSeek = true; canVolume = tv.rendering != nil
        commandTask = Task {
            var ownedRelay: MediaRelay?
            var preparedFile: URL?
            do {
                let source: PlaybackSource
                if let offlineID { source = try await downloads.offlineSource(offlineID) } else { source = try await service.playback(selection) }
                try Task.checkCancellation()
                let useRelay = forceRelay || source.offline || !source.requestHeaders.isEmpty
                var url = source.url
                if useRelay {
                    guard let local = DLNAClient.localAddress() else { throw DLNAError.command("请连接与电视相同的 Wi-Fi 后重试") }
                    var prepared = source
                    if source.offline && source.kind == .hls {
                        // Use the documented export capability, never parse Apple's private movpkg layout.
                        prepared = try await exportOffline(source); preparedFile = prepared.url
                    }
                    let proxy = try MediaRelay(source: prepared, address: local, allowedPeer: tv.address)
                    ownedRelay = proxy; url = try await proxy.start()
                }
                try await client.load(tv, url: url, title: selection.work.title + " · " + selection.episode.name, kind: source.offline && source.kind == .hls ? .progressive : source.kind)
                try Task.checkCancellation(); guard generation == token else { ownedRelay?.stop(); return }
                if position > 0 { _ = try? await client.action(tv, "Seek", arguments: [("Unit", "REL_TIME"), ("Target", TVXML.time(position))]) }
                releaseMedia(); relay = ownedRelay; exportURL = preparedFile
                self.device = tv; self.selection = selection; self.service = service; self.watch = watch; self.downloads = downloads; self.offlineID = offlineID
                if let offlineID { downloads.protectCast(offlineID) }
                if userInitiated { watch.begin(selection) }
                relaying = useRelay; self.position = position; duration = 0; status = "等待电视确认播放"; busy = false
                pauseLocal(); monitor(tv, token: token)
            } catch {
                ownedRelay?.stop(); if let preparedFile { try? FileManager.default.removeItem(at: preparedFile) }; guard generation == token, !Task.isCancelled else { return }
                busy = false; status = "投屏失败"; self.error = error.localizedDescription
            }
        }
    }
    private func exportOffline(_ source: PlaybackSource) async throws -> PlaybackSource {
        let keys = try source.offlineKeys.map(OfflineContentKeys.init)
        let asset = AVURLAsset(url: source.url)
        guard let job = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough), job.supportedFileTypes.contains(.mp4) else { throw DLNAError.command("系统无法将这份离线 HLS 导出给电视。请在影片详情使用在线投屏或 AirPlay。") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rf-cast-\(UUID().uuidString).mp4")
        export = job; job.outputURL = url; job.outputFileType = .mp4
        await job.export()
        withExtendedLifetime(keys) {}
        guard job.status == .completed else { try? FileManager.default.removeItem(at: url); throw DLNAError.command("系统无法导出这份离线视频，请使用在线投屏。") }
        export = nil
        return PlaybackSource(url: url, offline: true)
    }
    private func monitor(_ tv: TVDevice, token: UUID) {
        pollTask?.cancel()
        pollTask = Task {
            var failures = 0; var previous: TVStatus?
            while !Task.isCancelled && generation == token {
                do {
                    try await Task.sleep(for: .seconds(2))
                    let value = try await client.status(tv); try Task.checkCancellation(); guard generation == token else { return }
                    failures = 0; position = value.position; duration = value.duration; error = nil
                    status = value.state == "PLAYING" ? "电视播放中" : value.state == "PAUSED_PLAYBACK" ? "电视已暂停" : value.state == "STOPPED" ? "电视已停止" : value.state
                    if value.state == "PLAYING", let selection { watch?.save(selection, position: value.position, duration: value.duration) }
                    if value.state == "STOPPED", let previous, previous.state == "PLAYING", previous.duration > 0, previous.position >= previous.duration - 5, UserDefaults.standard.object(forKey: "playback.autoNext") as? Bool != false, offlineID == nil,
                       let selection, let service, let downloads, let watch,
                       let next = try await EpisodeNavigator.next(after: selection, known: [], total: 0, service: service) {
                        connect(tv, selection: next, service: service, downloads: downloads, watch: watch, offlineID: nil, position: 0, forceRelay: relaying, pauseLocal: {}, userInitiated: false); return
                    }
                    previous = value
                } catch {
                    if Task.isCancelled { return }; failures += 1; self.error = "无法读取电视状态，请确认电视仍在播放"
                    if failures >= 4 { status = "电视连接中断"; return }
                }
            }
        }
    }
    func control(_ action: String, arguments: [(String, String)] = [], rendering: Bool = false) {
        guard let device, !busy else { return }
        Task {
            do { _ = try await client.action(device, action, arguments: arguments, rendering: rendering); error = nil }
            catch { self.error = error.localizedDescription; if action == "Seek" { canSeek = false }; if rendering { canVolume = false } }
        }
    }
    func stop() async {
        generation = UUID(); commandTask?.cancel(); pollTask?.cancel(); export?.cancelExport(); busy = false
        if let device { _ = try? await client.action(device, "Stop") }
        releaseMedia(); device = nil; status = "未连接"; position = 0; duration = 0; error = nil; relaying = false
    }
    private func releaseMedia() {
        relay?.stop(); relay = nil
        if let offlineID { downloads?.unprotectCast(offlineID) }; offlineID = nil
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }; exportURL = nil
    }
    func background() {
        pollTask?.cancel()
        if relaying { Task { await stop(); error = "手机中转已停止；请保持应用在前台后重新投屏。" } }
    }
    func foreground() { if let device { monitor(device, token: generation) } }
}

@MainActor struct CastScreen: View {
    let selection: MediaSelection
    let service: any CatalogService
    let downloads: DownloadCenter
    let watch: WatchStore
    let offlineID: String?
    let position: Double
    let pauseLocal: () -> Void
    @ObservedObject private var cast = CastModel.shared
    @State private var manual = ""
    @State private var forceRelay = false
    @State private var seek: Double = 0
    @State private var volume: Double = 50
    var body: some View {
        Form {
            Section("AirPlay") { AirPlayPicker().frame(height: 44); Text("支持 AirPlay 的电视可从上方系统按钮选择。").font(.caption) }
            Section("DLNA 电视") {
                Button(cast.searching ? "正在搜索…" : "搜索同一 Wi-Fi 的电视") { cast.search() }.disabled(cast.searching).accessibilityIdentifier("search_tv")
                ForEach(cast.devices) { tv in Button { cast.connect(tv, selection: selection, service: service, downloads: downloads, watch: watch, offlineID: offlineID, position: position, forceRelay: forceRelay, pauseLocal: pauseLocal) } label: { VStack(alignment: .leading) { Text(tv.name); Text(tv.address).font(.caption) } }.disabled(cast.busy) }
                Toggle("通过手机中转", isOn: $forceRelay)
                Text("手机中转需要保持应用前台。电视的格式、音轨和网络能力决定实际播放效果。").font(.caption)
            }
            Section("手动添加") {
                TextField("http://电视IP:端口/description.xml", text: $manual).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("添加设备") { Task { await cast.add(manual) } }.disabled(manual.isEmpty)
                Text("设备描述地址可在电视投屏应用的设备信息中查找。自动搜索需要签名包含 Apple 批准的组播权限；手动连接不需要组播权限。").font(.caption)
            }
            if cast.device != nil {
                Section(cast.device?.name ?? "当前电视") {
                    Text(cast.status); Text(TVXML.time(cast.position) + " / " + TVXML.time(cast.duration)).monospacedDigit()
                    HStack { Button("播放") { cast.control("Play", arguments: [("Speed", "1")]) }; Spacer(); Button("暂停") { cast.control("Pause") }; Spacer(); Button("停止投屏", role: .destructive) { Task { await cast.stop() } } }
                    Slider(value: $seek, in: 0...max(1, cast.duration), onEditingChanged: { editing in if !editing { cast.control("Seek", arguments: [("Unit", "REL_TIME"), ("Target", TVXML.time(seek))]) } }).disabled(!cast.canSeek || cast.duration <= 0)
                    HStack { Text("电视音量"); Slider(value: $volume, in: 0...100, onEditingChanged: { editing in if !editing { cast.control("SetVolume", arguments: [("Channel", "Master"), ("DesiredVolume", String(Int(volume)))], rendering: true) } }).disabled(!cast.canVolume) }
                }
            }
            if let error = cast.error { Section { Text(error).foregroundStyle(.red).font(.caption) } }
        }.onChange(of: cast.position) { _, value in seek = value }
    }
}
@MainActor struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let v = AVRoutePickerView(); v.prioritizesVideoDevices = true; return v }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
