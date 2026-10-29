import AVKit
import SwiftUI

@MainActor final class PlaybackModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var status = "正在获取播放地址"
    @Published private(set) var error: String?
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var ready = false
    @Published private(set) var playing = false
    @Published private(set) var speed: Float
    @Published private(set) var holding = false
    @Published private(set) var holdCount = 0
    @Published private(set) var lastHoldMilliseconds = 0
    private var holdStarted: TimeInterval?
    private var fixedSpeed: Float
    private let defaults: UserDefaults
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var generation = UUID()
    private var watch: WatchStore?
    private var selection: MediaSelection?
    private var hasPlayed = false
    private var wantsPlay = false
    private var endObserver: NSObjectProtocol?
    private var contentKeys: OfflineContentKeys?
    private var startupTask: Task<Void, Never>?
    private var relay: MediaRelay?
    private(set) var source: PlaybackSource?
    var offlineKeyResponses: Int { (contentKeys?.responseCount ?? 0) + (relay?.keyResponses ?? 0) }
    var onEnded: (() -> Void)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.float(forKey: "playback.speed")
        fixedSpeed = PlaybackPolicy.speeds.contains(saved) ? saved : 1; speed = fixedSpeed
    }
    func load(_ selection: MediaSelection, service: any CatalogService, watch: WatchStore? = nil, offlineID: String? = nil, downloads: DownloadCenter? = nil, beginSession: Bool = true, startAt: Double? = nil) async {
        stop(); error = nil; ready = false; position = 0; duration = 0; status = "正在获取播放地址"
        wantsPlay = true; self.watch = watch; self.selection = selection
        if beginSession { watch?.begin(selection) }
        let resume = startAt ?? watch?.resumePosition(selection) ?? 0
        let token = generation
        do {
            let source: PlaybackSource
            if let offlineID {
                guard let downloads else { throw DownloadFailure.missing }
                source = try await downloads.offlineSource(offlineID)
            } else { source = try await service.playback(selection) }
            try Task.checkCancellation(); guard generation == token else { return }
            self.source = source
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            var url = source.url, options: [String: Any] = [:]
            if source.requiresRelay {
                let proxy = try MediaRelay(source: source)
                url = try await proxy.start(); guard generation == token, !Task.isCancelled else { proxy.stop(); return }; relay = proxy
            } else if let agent = source.userAgent { options[AVURLAssetHTTPUserAgentKey] = agent }
            if let keyURL = source.offlineKeys { contentKeys = try OfflineContentKeys(url: keyURL) }
            let asset = AVURLAsset(url: url, options: options)
            try Task.checkCancellation(); guard generation == token else { return }
            let item = AVPlayerItem(asset: asset)
            // A loopback relay cannot be fetched by a TV through AirPlay's direct mode.
            player.allowsExternalPlayback = !source.offline && !source.requiresRelay
            player.automaticallyWaitsToMinimizeStalling = !source.offline
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, generation == token else { return }
                    persist(); releaseHold(); playing = false; onEnded?()
                }
            }
            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, generation == token else { return }
                    if item.status == .failed { error = "视频无法播放，可重试或切换线路。"; status = "播放失败"; playing = false }
                    else if item.status == .readyToPlay {
                        ready = true
                        startupTask = Task { @MainActor [weak self] in
                            guard let self else { return }
                            if resume > 0 { await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
                            guard generation == token, !Task.isCancelled else { return }
                            if wantsPlay { play() }
                        }
                    }
                }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self, generation == token else { return }
                    position = time.seconds.isFinite ? max(0, time.seconds) : 0
                    let length = player.currentItem?.duration.seconds ?? 0
                    duration = length.isFinite ? max(0, length) : 0
                    playing = player.timeControlStatus == .playing
                    if ready && position > 0.1 { hasPlayed = true }
                    if hasPlayed && Int(position) % 5 == 0 { persist() }
                    if ready { status = playing ? "正在播放" : player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? "正在缓冲" : "已暂停" }
                }
            }
            status = "正在加载视频"; player.defaultRate = fixedSpeed; player.replaceCurrentItem(with: item)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription; status = "播放失败"; relay?.stop(); relay = nil
        }
    }
    func setSpeed(_ value: Float) {
        guard PlaybackPolicy.speeds.contains(value) else { return }
        fixedSpeed = value; defaults.set(value, forKey: "playback.speed"); applySpeed(value)
    }
    private func applySpeed(_ value: Float) {
        speed = value; player.defaultRate = fixedSpeed
        if player.timeControlStatus == .playing { player.rate = value }
    }
    func hold() {
        guard ready, player.timeControlStatus == .playing, !holding else { return }
        holding = true; holdCount += 1; lastHoldMilliseconds = 0; holdStarted = ProcessInfo.processInfo.systemUptime
        let saved = defaults.float(forKey: "playback.holdSpeed")
        applySpeed(max(fixedSpeed, [Float(2), 2.5, 3].contains(saved) ? saved : 2))
    }
    func releaseHold() {
        if let holdStarted { lastHoldMilliseconds = max(0, Int((ProcessInfo.processInfo.systemUptime - holdStarted) * 1000)); self.holdStarted = nil }
        holding = false; applySpeed(fixedSpeed)
    }
    func seek(_ value: Double) {
        guard ready, duration > 0, value.isFinite else { return }
        releaseHold(); player.seek(to: CMTime(seconds: min(max(0, value), duration), preferredTimescale: 600))
    }
    func play() { wantsPlay = true; guard ready else { return }; player.playImmediately(atRate: fixedSpeed); playing = true }
    func toggle() { if player.timeControlStatus == .paused { play() } else { pause() } }
    private func persist() {
        guard hasPlayed, let selection, let item = player.currentItem else { return }
        watch?.save(selection, position: player.currentTime().seconds, duration: item.duration.seconds)
    }
    func pause() { wantsPlay = false; startupTask?.cancel(); releaseHold(); player.pause(); playing = false; persist() }
    func stop() {
        persist(); wantsPlay = false; generation = UUID(); startupTask?.cancel(); startupTask = nil
        releaseHold(); player.pause(); itemObservation = nil
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer); endObserver = nil }
        hasPlayed = false; ready = false; playing = false
        if let observer = timeObserver { player.removeTimeObserver(observer); timeObserver = nil }
        player.replaceCurrentItem(with: nil); contentKeys = nil; source = nil; relay?.stop(); relay = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// One control layer: AVPlayerLayer draws video; SwiftUI owns all playback chrome.
@MainActor struct NativePlayer: UIViewRepresentable {
    let player: AVPlayer
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> Surface { let view = Surface(); view.backgroundColor = .black; view.isUserInteractionEnabled = false; view.videoLayer.videoGravity = .resizeAspect; return view }
    func updateUIView(_ view: Surface, context: Context) { view.videoLayer.player = player }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.videoLayer.player = nil }
}
