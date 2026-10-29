import AVKit
import SwiftUI

enum PlayerPanel: String, Identifiable { case speed, episodes, lines, more, cast; var id: String { rawValue } }
@MainActor struct PlaybackScreen: View {
    let service: any CatalogService
    @State private var queue: [VideoEpisode]
    @State private var episodeTotal: Int
    @State private var lines: [VideoLine] = []
    @State private var selection: MediaSelection
    @State private var offlineID: String?
    @State private var busy = false
    @State private var message: String?
    @State private var selectionTask: Task<Void, Never>?
    @State private var beginSession = true
    @State private var startAt: Double?
    @State private var locked = false
    @State private var chrome = true
    @State private var panel: PlayerPanel?
    @State private var hideTask: Task<Void, Never>?
    @State private var interacting = false
    @State private var feedback: String?
    @State private var dragStart: (Double, CGFloat, Float)?
    @State private var preview: Double?
    @State private var landscape = false
    @State private var originalBrightness: CGFloat?
    @State private var originalIdleDisabled = false
    @AppStorage("playback.autoNext") private var autoNext = true
    @AppStorage("playback.holdSpeed") private var holdSpeed = 2.0
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var downloads: DownloadCenter
    @StateObject private var model = PlaybackModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    init(selection: MediaSelection, service: any CatalogService, queue: [VideoEpisode] = [], episodeTotal: Int = 0, offlineID: String? = nil, position: Double? = nil) {
        self.service = service; _queue = State(initialValue: queue); _episodeTotal = State(initialValue: episodeTotal)
        _selection = State(initialValue: selection); _offlineID = State(initialValue: offlineID); _startAt = State(initialValue: position)
    }
    private var nextOffline: DownloadEntry? {
        let matching = downloads.entries.filter { $0.state == .complete && $0.selection.work.sourceKey == selection.work.sourceKey && $0.selection.lineKey == selection.lineKey }
        if selection.work.providerID != "jianpian" {
            guard let n = selection.episode.number else { return nil }; let next = matching.filter { $0.selection.episode.number == n + 1 }; return next.count == 1 ? next.first : nil
        }
        return matching.first { $0.selection.episode.index == selection.episode.index + 1 }
    }
    private var hasNext: Bool {
        if offlineID != nil { return nextOffline != nil }
        if selection.work.providerID != "jianpian" {
            guard let number = selection.episode.number else { return false }
            return queue.filter { $0.number == number + 1 && $0.unsupportedReason == nil }.count == 1 || queue.count < episodeTotal
        }
        return queue.firstIndex(where: { $0.key == selection.episode.key }).map { $0 + 1 < queue.count || queue.count < episodeTotal } ?? true
    }
    private var title: String { selection.work.title + " · " + selection.episode.name }
    private var lineName: String { lines.first { $0.key == selection.lineKey }?.name ?? selection.lineKey }
    private func wake() { chrome = true; scheduleHide() }
    private func scheduleHide() {
        hideTask?.cancel()
        guard chrome, PlaybackPolicy.canHide(playing: model.playing, locked: locked, panel: panel != nil, interacting: interacting || model.holding) else { return }
        hideTask = Task { try? await Task.sleep(for: .seconds(PlaybackPolicy.hideDelay)); guard !Task.isCancelled else { return }; withAnimation(.easeOut(duration: 0.2)) { chrome = false } }
    }
    private func open(_ value: PlayerPanel) { guard !locked else { return }; model.releaseHold(); panel = value; wake() }
    private func setLock(_ value: Bool) {
        model.releaseHold(); locked = value; panel = nil; feedback = nil; preview = nil; interacting = false
        PlayerOrientation.set(value ? (landscape ? .landscape : .portrait) : .allButUpsideDown, rotate: false); wake()
    }
    private func fullscreen() { guard !locked else { return }; model.releaseHold(); panel = nil; PlayerOrientation.set(landscape ? .portrait : .landscape); wake() }
    private func back() { if locked { wake() } else if panel != nil { panel = nil; wake() } else if landscape { fullscreen() } else { dismiss() } }
    private func select(_ target: MediaSelection, offline: String? = nil, begin: Bool = true, position: Double? = nil) {
        guard !locked else { return }
        if target.id == selection.id && offlineID == offline {
            beginSession = begin; startAt = position ?? 0; panel = nil
            Task { await load() }; return
        }
        model.stop(); if let offlineID { downloads.unprotect(offlineID) }
        beginSession = begin; startAt = position; offlineID = offline
        selection = target; panel = nil; setLock(false); wake()
    }
    private func next(userInitiated: Bool) {
        guard !busy, !locked else { return }; busy = true; message = nil
        selectionTask = Task {
            defer { busy = false }
            do {
                if offlineID != nil { if let entry = nextOffline { select(entry.selection, offline: entry.id, begin: userInitiated) }; return }
                guard let target = try await EpisodeNavigator.next(after: selection, known: queue, total: episodeTotal, service: service) else { if userInitiated { message = "已没有下一集" }; return }
                try Task.checkCancellation()
                select(target, begin: userInitiated)
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    private func changeLine(_ line: VideoLine) {
        guard line.playable, line.key != selection.lineKey, !busy, offlineID == nil else { panel = nil; return }
        busy = true; message = nil
        selectionTask = Task {
            defer { busy = false }
            do {
                let items = try await PlaybackCatalog.episodes(selection, line: line.key, service: service)
                guard let match = PlaybackPolicy.matching(selection, in: items) else { throw CatalogError.message("该线路没有唯一匹配的剧集，已保留当前播放。请在详情页重新选集。") }
                try Task.checkCancellation(); queue = items; episodeTotal = items.count
                select(MediaSelection(work: selection.work, episode: match, lineKey: line.key), position: 0)
            } catch { if !Task.isCancelled { message = error.localizedDescription; panel = nil } }
        }
    }
    private func retry() { startAt = model.position; Task { await load() } }
    private func load() async {
        if let offlineID { downloads.protect(offlineID) }
        model.onEnded = { if autoNext && hasNext { if locked { setLock(false) }; next(userInitiated: false) } }
        await model.load(selection, service: service, watch: watch, offlineID: offlineID, downloads: downloads, beginSession: beginSession, startAt: startAt)
        startAt = nil
    }
    private func catalog() async {
        guard offlineID == nil else { return }
        let current = selection
        do {
            let manifest = try await service.manifest(current.work)
            let episodes = try await PlaybackCatalog.episodes(current, line: current.lineKey, service: service)
            try Task.checkCancellation(); guard selection.id == current.id else { return }
            lines = manifest.lines; queue = episodes; episodeTotal = episodes.count
        } catch { if !Task.isCancelled { message = "选集加载失败：" + error.localizedDescription } }
    }
    private func downloadCurrent() { let count = downloads.enqueue([selection]); message = count > 0 ? "已加入下载，继续当前播放" : "本集已在下载列表中"; panel = nil }
    private func drag(_ start: CGPoint, _ delta: CGPoint, _ size: CGSize, _ ended: Bool) {
        guard !locked else { return }
        if dragStart == nil { dragStart = (model.position, UIScreen.main.brightness, model.player.volume); interacting = true; chrome = false }
        guard let initial = dragStart else { return }
        if abs(delta.x) > abs(delta.y) {
            preview = min(max(0, initial.0 + Double(delta.x / max(1, size.width)) * 120), model.duration)
            feedback = TVXML.time(preview ?? 0) + " / " + TVXML.time(model.duration)
        } else if start.x < size.width / 2 {
            let value = min(max(0.02, initial.1 - delta.y / max(1, size.height)), 1); UIScreen.main.brightness = value; feedback = "亮度 \(Int(value * 100))%"
        } else {
            let value = min(max(0, initial.2 - Float(delta.y / max(1, size.height))), 1); model.player.volume = value; feedback = "音量 \(Int(value * 100))%"
        }
        if ended { if let preview { model.seek(preview) }; dragStart = nil; preview = nil; feedback = nil; interacting = false; wake() }
    }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            VStack(spacing: 0) {
                if !wide && !locked { HStack { Button("关闭", action: back).accessibilityIdentifier("close_player"); Spacer(); Text("播放").font(.headline); Spacer(); Color.clear.frame(width: 44) }.padding(.horizontal).frame(height: 44) }
                video(wide: wide).frame(height: wide ? geometry.size.height : geometry.size.width * 9 / 16)
                if !wide && !locked { portrait }
            }.background(Color(.systemGroupedBackground))
                .onAppear { landscape = wide }
                .onChange(of: wide) { _, value in landscape = value; model.releaseHold(); panel = nil; interacting = false; wake() }
        }
        .statusBarHidden(landscape || locked)
        .sheet(item: Binding(get: { landscape ? nil : panel }, set: { panel = $0; wake() })) { value in
            NavigationStack { panelContent(value).navigationTitle(panelTitle(value)).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { panel = nil; wake() } } } }.presentationDetents([.medium, .large])
        }
        .task(id: selection.id) { await load() }
        .task(id: selection.id + (offlineID ?? "online")) { await catalog() }
        .onAppear { originalBrightness = UIScreen.main.brightness; originalIdleDisabled = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            selectionTask?.cancel(); hideTask?.cancel(); model.onEnded = nil; model.stop()
            if let offlineID { downloads.unprotect(offlineID) }
            if let originalBrightness { UIScreen.main.brightness = originalBrightness }; UIApplication.shared.isIdleTimerDisabled = originalIdleDisabled
            PlayerOrientation.set(.allButUpsideDown, rotate: false)
        }
        .onChange(of: model.playing) { _, value in if !value { wake() } else { scheduleHide() } }
        .onChange(of: model.holding) { _, _ in scheduleHide() }
        .onChange(of: scenePhase) { _, value in if value != .active { model.pause(); interacting = false; dragStart = nil; feedback = nil } }
    }
    private func video(wide: Bool) -> some View {
        ZStack {
            NativePlayer(player: model.player).allowsHitTesting(false).accessibilityIdentifier("native_player")
            PlayerTouchSurface(locked: locked, tap: { chrome.toggle(); scheduleHide() }, doubleTap: { model.toggle(); wake() }, hold: { active in
                if active { model.hold(); chrome = false } else { model.releaseHold(); scheduleHide() }
            }, cancel: { model.releaseHold(); dragStart = nil; preview = nil; feedback = nil; interacting = false; wake() }, drag: drag)
            if chrome && !locked && panel == nil {
                PlayerChrome(model: model, landscape: wide, title: title, hasNext: hasNext && !busy, close: back, fullscreen: fullscreen, lock: { setLock(true) }, cast: { open(.cast) }, speed: { open(.speed) }, episodes: { open(.episodes) }, more: { open(.more) }, next: { next(userInitiated: true) }, interact: { interacting = $0; wake() })
            }
            if locked && chrome { HStack { Button { setLock(false) } label: { Image(systemName: "lock.fill").frame(width: 50, height: 50).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("解锁画面").accessibilityIdentifier("player_unlock"); Spacer() }.padding().foregroundStyle(.white) }
            if model.holding { Text("\(model.speed.formatted())× 加速中，松手恢复").padding(10).background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).accessibilityIdentifier("hold_feedback").allowsHitTesting(false) }
            if let feedback { Text(feedback).padding(10).background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white) }
            if busy { ProgressView().tint(.white).allowsHitTesting(false) }
            if wide, let value = panel {
                HStack(spacing: 0) {
                    Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { panel = nil; wake() }
                    VStack {
                        HStack { Text(panelTitle(value)).font(.headline); Spacer(); Button("关闭面板") { panel = nil; wake() }.accessibilityIdentifier("close_panel") }.padding()
                        panelContent(value)
                    }.frame(width: min(380, UIScreen.main.bounds.width * 0.5)).background(Color(.systemBackground))
                }.accessibilityIdentifier("player_panel")
            }
        }.background(.black).clipped()
    }
    private var portrait: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(selection.work.title).font(.title2.bold())
                Text(selection.episode.name).foregroundStyle(.secondary).accessibilityIdentifier("playing_episode")
                Text(selection.work.sourceName + " · " + lineName).font(.caption).foregroundStyle(.secondary)
                Text(model.status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("playback_status")
                HStack {
                    Button("倍速") { open(.speed) }.accessibilityIdentifier("below_speed")
                    Spacer(); Button("线路") { open(.lines) }.disabled(offlineID != nil).accessibilityIdentifier("below_lines")
                    Spacer(); Button("下载本集", action: downloadCurrent).disabled(offlineID != nil)
                    Spacer(); Button("下一集") { next(userInitiated: true) }.disabled(!hasNext || busy)
                }.font(.subheadline)
                Toggle("自动下一集", isOn: $autoNext)
                if let error = model.error { Text(error).foregroundStyle(.red); Button("重试播放", action: retry) }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("player_message") }
                if offlineID != nil { Label("离线观看", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                if !queue.isEmpty && offlineID == nil {
                    HStack { Text("选集").font(.headline); Spacer(); Button("全部 \(queue.count) 集") { open(.episodes) } }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))]) { ForEach(queue.prefix(20)) { episode in episodeButton(episode) } }
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    Text(model.ready && model.position >= 0.5 ? "已解码并推进" : "等待解码").font(.caption).accessibilityIdentifier("decode_check")
                    Text("\(model.speed.formatted())×").accessibilityIdentifier("speed_check")
                    Text(String(model.holdCount)).accessibilityIdentifier("hold_count")
                    Text(String(model.lastHoldMilliseconds)).accessibilityIdentifier("hold_ms")
                }
                #endif
            }.padding(20)
        }
    }
    private func panelTitle(_ value: PlayerPanel) -> String { switch value { case .speed: return "播放速度"; case .episodes: return "选集"; case .lines: return "播放线路"; case .more: return "播放设置"; case .cast: return "投屏" } }
    @ViewBuilder private func panelContent(_ value: PlayerPanel) -> some View {
        switch value {
        case .speed:
            List {
                Section("长按画面临时加速，松手恢复") { ForEach(PlaybackPolicy.speeds, id: \.self) { speed in Button { model.setSpeed(speed); panel = nil; wake() } label: { HStack { Text("\(speed.formatted())×"); Spacer(); if model.speed == speed { Image(systemName: "checkmark") } } }.accessibilityIdentifier("speed_\(speed)") } }
            }
        case .episodes:
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))]) { ForEach(queue) { episode in episodeButton(episode) } }.padding() }
        case .lines:
            List(lines) { line in Button { changeLine(line) } label: { HStack { Text(line.name); Spacer(); if selection.lineKey == line.key { Image(systemName: "checkmark") }; if !line.playable { Text(line.unsupportedReason ?? "需授权").font(.caption) } } }.disabled(!line.playable || busy || offlineID != nil).accessibilityIdentifier("playing_line_\(line.key)") }
        case .more:
            Form {
                Button("播放速度 · \(model.speed.formatted())×") { panel = .speed }
                Button("播放线路 · " + lineName) { panel = .lines }.disabled(offlineID != nil)
                Button("选集") { panel = .episodes }.disabled(offlineID != nil)
                Button("下载本集", action: downloadCurrent).disabled(offlineID != nil)
                Button("锁定画面") { setLock(true) }
                Toggle("自动下一集", isOn: $autoNext)
                Picker("长按倍速", selection: $holdSpeed) { ForEach([2.0, 2.5, 3.0], id: \.self) { Text("\($0.formatted())×").tag($0) } }
                Text("轻点显隐控制，双击播放暂停；横滑调整进度，左侧上下滑调亮度，右侧调本机视频音量。").font(.caption)
            }
        case .cast:
            CastScreen(selection: selection, service: service, downloads: downloads, watch: watch, offlineID: offlineID, position: model.position, pauseLocal: model.pause, returnToPhone: { target, position in select(target, offline: offlineID, position: position) })
        }
    }
    private func episodeButton(_ episode: VideoEpisode) -> some View {
        Button(episode.name) { select(MediaSelection(work: selection.work, episode: episode, lineKey: selection.lineKey), position: 0) }.buttonStyle(.bordered).tint(episode.key == selection.episode.key ? .accentColor : .secondary).disabled(episode.unsupportedReason != nil || offlineID != nil || busy).accessibilityIdentifier("playing_episode_\(episode.key)")
    }
}
