import AVKit
import SwiftUI

@MainActor final class PlaybackModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var status = "正在获取播放地址"
    @Published private(set) var error: String?
    @Published private(set) var position: Double = 0
    @Published private(set) var ready = false
    @Published private(set) var speed: Float = 1
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var generation = UUID()
    private var watch: WatchStore?
    private var selection: MediaSelection?
    private var hasPlayed = false
    private var endObserver: NSObjectProtocol?
    private var contentKeys: OfflineContentKeys?
    private var offlineStartPosition: Double?
    private var startupTask: Task<Void, Never>?
    var offlineKeyResponses: Int { contentKeys?.responseCount ?? 0 }
    var onEnded: (() -> Void)?
    func load(_ selection: MediaSelection, service: any CatalogService, watch: WatchStore? = nil, offlineID: String? = nil, downloads: DownloadCenter? = nil, beginSession: Bool = true) async {
        stop(); error = nil; ready = false; position = 0; status = "正在获取播放地址"
        self.watch = watch; self.selection = selection
        if beginSession { watch?.begin(selection) }
        let resume = watch?.resumePosition(selection) ?? 0
        let token = generation
        do {
            let source: PlaybackSource
            if let offlineID {
                guard let downloads else { throw DownloadFailure.missing }
                source = try await downloads.offlineSource(offlineID)
            } else { source = try await service.playback(selection) }
            try Task.checkCancellation()
            guard generation == token else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            var options: [String: Any] = [:]
            if let agent = source.userAgent { options[AVURLAssetHTTPUserAgentKey] = agent }
            if let keyURL = source.offlineKeys { contentKeys = try OfflineContentKeys(url: keyURL) }
            let asset = AVURLAsset(url: source.url, options: options)
            try Task.checkCancellation(); guard generation == token else { return }
            let item = AVPlayerItem(asset: asset)
            offlineStartPosition = source.offline ? resume : nil
            player.allowsExternalPlayback = !source.offline
            player.automaticallyWaitsToMinimizeStalling = !source.offline
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, generation == token else { return }
                    persist(); onEnded?()
                }
            }
            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, generation == token else { return }
                    if item.status == .failed {
                        error = "视频无法播放，请返回详情重试或换线路。"; status = "播放失败"
                    } else if item.status == .readyToPlay {
                        ready = true; status = "正在播放"
                        if let resume = offlineStartPosition {
                            offlineStartPosition = nil
                            startupTask = Task { @MainActor [weak self] in
                                guard let self else { return }
                                if resume > 0 { await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
                                guard generation == token, !Task.isCancelled else { return }
                                player.playImmediately(atRate: speed)
                            }
                        }
                    }
                }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self, generation == token else { return }
                    position = time.seconds.isFinite ? time.seconds : 0
                    if ready && position > 0.1 { hasPlayed = true }
                    if hasPlayed && Int(position) % 5 == 0 { persist() }
                    if ready { status = player.timeControlStatus == .playing ? "正在播放" : player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? "正在缓冲" : "已暂停" }
                }
            }
            status = "正在加载视频"; player.replaceCurrentItem(with: item); player.defaultRate = speed
            if !source.offline, resume > 0 { await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
            try Task.checkCancellation(); guard generation == token else { return }
            if !source.offline { player.play() }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription; status = "播放失败"
        }
    }
    func setSpeed(_ value: Float) {
        speed = value; player.defaultRate = value
        if player.timeControlStatus == .playing { player.rate = value }
    }
    private func persist() {
        guard hasPlayed, let selection, let item = player.currentItem else { return }
        watch?.save(selection, position: player.currentTime().seconds, duration: item.duration.seconds)
    }
    func pause() { offlineStartPosition = nil; startupTask?.cancel(); player.pause(); persist() }
    func stop() {
        persist(); generation = UUID(); player.pause(); itemObservation = nil
        offlineStartPosition = nil; startupTask?.cancel(); startupTask = nil
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer); endObserver = nil }
        hasPlayed = false; ready = false
        if let observer = timeObserver { player.removeTimeObserver(observer); timeObserver = nil }
        player.replaceCurrentItem(with: nil)
        contentKeys = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
@MainActor struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player; controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}
@MainActor struct PlaybackScreen: View {
    let service: any CatalogService
    @State private var queue: [VideoEpisode]
    let episodeTotal: Int
    @State private var selection: MediaSelection
    @State private var offlineID: String?
    @State private var advancing = false
    @State private var nextError: String?
    @State private var nextTask: Task<Void, Never>?
    @State private var beginSession = true
    @AppStorage("playback.autoNext") private var autoNext = true
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var downloads: DownloadCenter
    @StateObject private var model = PlaybackModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    init(selection: MediaSelection, service: any CatalogService, queue: [VideoEpisode] = [], episodeTotal: Int = 0, offlineID: String? = nil) {
        self.service = service; _queue = State(initialValue: queue); self.episodeTotal = episodeTotal
        _selection = State(initialValue: selection); _offlineID = State(initialValue: offlineID)
    }
    private var nextOffline: DownloadEntry? {
        let matching = downloads.entries.filter { $0.state == .complete && $0.selection.work.sourceKey == selection.work.sourceKey && $0.selection.lineKey == selection.lineKey }
        if selection.work.providerID != "jianpian" {
            guard let n = selection.episode.number else { return nil }
            let next = matching.filter { $0.selection.episode.number == n + 1 }
            return next.count == 1 ? next.first : nil
        }
        return matching.first { $0.selection.episode.index == selection.episode.index + 1 }
    }
    private var hasNext: Bool {
        if offlineID != nil { return nextOffline != nil }
        if selection.work.providerID != "jianpian", selection.episode.number == nil { return false }
        if queue.isEmpty || episodeTotal <= 0 { return true }
        return queue.firstIndex(where: { $0.key == selection.episode.key }).map { $0 + 1 < queue.count || queue.count < episodeTotal } ?? false
    }
    private func next(userInitiated: Bool) {
        guard !advancing else { return }; advancing = true; nextError = nil
        nextTask = Task {
            defer { advancing = false }
            do {
                let target: MediaSelection?
                let targetOfflineID: String?
                if offlineID != nil { let entry = nextOffline; target = entry?.selection; targetOfflineID = entry?.id }
                else { target = try await EpisodeNavigator.next(after: selection, known: queue, total: episodeTotal, service: service); targetOfflineID = nil }
                try Task.checkCancellation()
                guard let target else { if userInitiated { nextError = "已没有下一集" }; return }
                model.stop()
                if let offlineID { downloads.unprotect(offlineID) }
                beginSession = userInitiated; offlineID = targetOfflineID
                if !queue.contains(where: { $0.key == target.episode.key }) { queue.append(target.episode) }
                selection = target
            } catch { if !Task.isCancelled { nextError = error.localizedDescription } }
        }
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                VStack(spacing: 0) {
                    NativePlayer(player: model.player)
                        .frame(height: landscape ? geometry.size.height : geometry.size.width * 9 / 16)
                        .background(.black).accessibilityIdentifier("native_player")
                    if !landscape {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(selection.work.title).font(.title2.bold())
                            Text(selection.episode.name).foregroundStyle(.secondary).accessibilityIdentifier("playing_episode")
                            HStack {
                                Text(model.status).foregroundStyle(.secondary).accessibilityIdentifier("playback_status")
                                Spacer()
                                Menu {
                                    ForEach([Float(0.5), 1, 1.25, 1.5, 2], id: \.self) { value in
                                        Button("\(value.formatted())×") { model.setSpeed(value) }
                                    }
                                } label: { Label("\(model.speed.formatted())×", systemImage: "speedometer") }
                            }
                            if let error = model.error {
                                Text(error).foregroundStyle(.red)
                                Button("重试播放") { Task { await model.load(selection, service: service, watch: watch, offlineID: offlineID, downloads: downloads) } }
                            }
                            HStack {
                                Button("下一集", systemImage: "forward.end") { next(userInitiated: true) }.disabled(!hasNext || advancing)
                                Spacer()
                                Toggle("自动下一集", isOn: $autoNext).font(.caption).fixedSize()
                            }
                            if let nextError { Text(nextError).font(.caption).foregroundStyle(.red) }
                            if offlineID != nil { Label("离线观看", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                            Text("播放、进度和全屏操作使用系统播放器控件。")
                                .font(.footnote).foregroundStyle(.secondary)
                            #if DEBUG
                            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                                Text(model.ready && model.position >= 0.5 ? "已解码并推进" : "等待解码")
                                    .font(.caption).accessibilityIdentifier("decode_check")
                            }
                            #endif
                        }.padding(20)
                        Spacer()
                    }
                }
            }
            .navigationTitle("播放").navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() }.foregroundStyle(.white).accessibilityIdentifier("close_player") } }
        }
        .task(id: selection.id) {
            if let offlineID { downloads.protect(offlineID) }
            model.onEnded = { if autoNext && hasNext { next(userInitiated: false) } }
            await model.load(selection, service: service, watch: watch, offlineID: offlineID, downloads: downloads, beginSession: beginSession)
        }
        .onDisappear { nextTask?.cancel(); model.onEnded = nil; model.stop(); if let offlineID { downloads.unprotect(offlineID) } }
        .onChange(of: scenePhase) { _, value in if value != .active { model.pause() } }
    }
}
