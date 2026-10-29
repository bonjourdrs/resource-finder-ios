import XCTest
import AVFoundation
import UIKit
@testable import ResourceFinder

@MainActor final class DownloadTests: XCTestCase {
    private var selection: MediaSelection { MediaSelection(work: FixtureCatalogService.work, episode: .init(key: "1", index: 0, name: "第1集"), lineKey: "xl") }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)", isDirectory: true) }
    private func wait(_ condition: () -> Bool, timeout: Double = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard condition() else {
            XCTFail("Download condition did not complete within \(timeout)s")
            throw NSError(domain: "DownloadTestTimeout", code: 1)
        }
    }
    func testMP4DownloadSurvivesReloadAndPlaysWithoutOriginOrResolver() async throws { try await offlineRoundTrip(path: "video.mp4", kind: .progressive) }
    func testHLSDownloadPlaysWithOriginStopped() async throws { try await offlineRoundTrip(path: "hls_index.m3u8", kind: .hls) }
    func testAES128HLSDownloadPlaysWithOriginStopped() async throws { try await offlineRoundTrip(path: "aes_index.m3u8", kind: .hls) }
    func testHeaderProtectedMP4DownloadOfflineRoundTrip() async throws { try await offlineRoundTrip(path: "video.mp4", kind: .progressive, headers: ["Referer": "https://fixture.example/"]) }
    func testHeaderProtectedAES128DownloadOfflineRoundTrip() async throws { try await offlineRoundTrip(path: "aes_index.m3u8", kind: .hls, headers: ["Referer": "https://fixture.example/", "Origin": "https://fixture.example"]) }
    func testMissingAESKeysFailLocallyWithoutResolver() async throws { try await offlineRoundTrip(path: "aes_index.m3u8", kind: .hls, eraseKeys: true) }
    func testHLSFixtureRendersOnline() async throws {
        let server = try LocalFixtureServer(files: LocalFixtureServer.bundledFiles())
        try await server.start(); defer { server.stop() }
        let player = AVPlayer(url: server.baseURL.appendingPathComponent("hls_index.m3u8"))
        let surface = try PlayerTestSurface(player: player)
        defer { player.pause(); surface.close() }
        player.play()
        try await wait({ player.currentItem?.status == .readyToPlay && player.currentTime().seconds >= 0.5 && surface.layer.isReadyForDisplay }, timeout: 10)
    }
    private func offlineRoundTrip(path: String, kind: MediaKind, eraseKeys: Bool = false, headers: [String: String] = [:]) async throws {
        let root = directory(), server = try LocalFixtureServer(files: LocalFixtureServer.bundledFiles(), requiredHeaders: headers)
        try await server.start()
        let service = DownloadTestService(sources: [PlaybackSource(url: server.baseURL.appendingPathComponent(path), kind: kind, headers: headers)])
        let center = DownloadCenter(root: root, namespace: "rf.tests.\(UUID().uuidString)")
        defer { center.shutdown(); server.stop(); try? FileManager.default.removeItem(at: root) }
        center.configure(service: service)
        XCTAssertEqual(center.enqueue([selection, selection]), 1)
        try await wait { center.entries.first?.state == .complete || center.entries.first?.state == .failed }
        XCTAssertEqual(center.entries.first?.state, .complete, center.entries.first?.error ?? "")
        guard center.entries.first?.state == .complete else { return }
        XCTAssertEqual(service.playbackCalls, 0)
        XCTAssertEqual(service.downloadCalls, 1)
        XCTAssertGreaterThan(server.requestCount, 0)
        server.stop()
        let restored = DownloadCenter(root: root, namespace: "rf.readonly.\(UUID().uuidString)")
        XCTAssertEqual(restored.entries.first?.state, .complete)
        let offline = try await restored.offlineSource(selection.id)
        print("offline-round-trip: \(path) local source validated")
        if kind == .hls {
            print("offline-package: \(offline.url.absoluteString); children=\((try? FileManager.default.contentsOfDirectory(atPath: offline.url.path)) ?? [])")
        }
        XCTAssertTrue(offline.url.isFileURL); XCTAssertTrue(offline.offline)
        if kind == .hls {
            XCTAssertEqual(try HLSKeys.read(XCTUnwrap(offline.offlineKeys)).count, path.hasPrefix("aes_") ? 1 : 0)

        }
        if eraseKeys {
            try JSONEncoder().encode([String: Data]()).write(to: XCTUnwrap(offline.offlineKeys))
            do { _ = try await restored.offlineSource(selection.id); XCTFail("Missing keys must fail before opening a player") }
            catch { XCTAssertEqual(restored.entries.first?.state, .failed) }
            XCTAssertEqual(service.playbackCalls, 0); XCTAssertEqual(service.downloadCalls, 1)
            return
        }
        let player = PlaybackModel()
        let surface = try PlayerTestSurface(player: player.player)
        defer { player.stop(); surface.close() }
        await player.load(selection, service: service, offlineID: selection.id, downloads: restored)
        do { try await wait({ player.ready && player.position >= 0.5 && surface.layer.isReadyForDisplay }, timeout: 10) }
        catch {
            print("offline-player: ready=\(player.ready) display=\(surface.layer.isReadyForDisplay) position=\(player.position) duration=\(String(describing: player.player.currentItem?.duration.seconds)) rate=\(player.player.rate) control=\(player.player.timeControlStatus.rawValue) waiting=\(String(describing: player.player.reasonForWaitingToPlay)) status=\(player.status) error=\(String(describing: player.error)) itemStatus=\(String(describing: player.player.currentItem?.status.rawValue)) itemError=\(String(describing: player.player.currentItem?.error)) ranges=\(String(describing: player.player.currentItem?.loadedTimeRanges))")
            throw error
        }
        print("offline-round-trip: \(path) local decode advanced")
        if path.hasPrefix("aes_") { XCTAssertGreaterThan(player.offlineKeyResponses, 0) }
        var seekFinished = false
        player.player.seek(to: CMTime(seconds: 3, preferredTimescale: 600)) { finished in
            Task { @MainActor in seekFinished = finished }
        }
        try await wait({ seekFinished }, timeout: 10)
        player.player.play()
        try await wait({ player.position >= 4 }, timeout: 10)
        XCTAssertNil(player.error); XCTAssertEqual(service.playbackCalls, 0)
        player.stop()
        if kind == .hls {
            if !eraseKeys {
                let converted = try await CastModel().exportOffline(offline)
                defer { try? FileManager.default.removeItem(at: converted.url) }
                let asset = AVURLAsset(url: converted.url)
                let playable = try await asset.load(.isPlayable)
                XCTAssertTrue(playable)
                let image = try AVAssetImageGenerator(asset: asset).copyCGImage(at: .zero, actualTime: nil)
                XCTAssertEqual(image.width, 320)
                print("offline-TV-export: \(path) local MP4 decoded with origin stopped")
            }
        }
        try restored.remove(selection.id)
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: offline.url.path))
    }
    func testPauseResumeAndFreshDescriptorRetry() async throws {
        var files = try LocalFixtureServer.bundledFiles()
        var video = files["/video.mp4"]!
        let padding = 2 * 1024 * 1024
        var size = UInt32(padding + 8).bigEndian
        withUnsafeBytes(of: &size) { video.append(contentsOf: $0) }
        video.append(Data("free".utf8)); video.append(Data(count: padding)); files["/video.mp4"] = video
        let server = try LocalFixtureServer(files: files, chunkDelay: 0.01)
        try await server.start(); defer { server.stop() }
        let root = directory()
        let center = DownloadCenter(root: root, namespace: "rf.tests.\(UUID().uuidString)")
        defer { center.shutdown(); try? FileManager.default.removeItem(at: root) }
        let service = DownloadTestService(sources: [PlaybackSource(url: server.baseURL.appendingPathComponent("missing.mp4")), PlaybackSource(url: server.baseURL.appendingPathComponent("video.mp4"))])
        center.configure(service: service); center.enqueue([selection])
        try await wait { center.entries.first?.state == .failed }
        center.resume(selection.id)
        try await wait { (center.entries.first?.bytes ?? 0) > 0 || center.entries.first?.state == .failed }
        center.pause(selection.id)
        XCTAssertEqual(center.entries.first?.state, .paused)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(center.entries.first?.state, .paused)
        center.resume(selection.id)
        try await wait { center.entries.first?.state == .complete || center.entries.first?.state == .failed }
        XCTAssertEqual(center.entries.first?.state, .complete, center.entries.first?.error ?? "")
        XCTAssertEqual(service.downloadCalls, 2)
        try center.remove(selection.id)
    }
    func testPausedIntentPersistsAndQueueDoesNotDuplicate() throws {
        let root = directory(), center = DownloadCenter(root: root, namespace: "rf.tests.\(UUID().uuidString)")
        defer { center.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(center.enqueue([selection, selection]), 1)
        center.pause(selection.id)
        let restored = DownloadCenter(root: root, namespace: "rf.read.\(UUID().uuidString)")
        XCTAssertEqual(restored.entries.count, 1); XCTAssertEqual(restored.entries.first?.state, .paused)
        center.protect(selection.id); XCTAssertThrowsError(try center.remove(selection.id))
        center.unprotect(selection.id); try center.remove(selection.id)
        XCTAssertTrue(DownloadCenter(root: root).entries.isEmpty)
    }
    func testBackgroundCompletionWaitsForValidation() {
        let bridge = DownloadBackgroundBridge(), id = UUID().uuidString
        var count = 0
        bridge.begin(id); bridge.register(id) { count += 1 }; bridge.finish(id)
        XCTAssertEqual(count, 0)
        bridge.end(id); XCTAssertEqual(count, 1)
        bridge.finish(id); XCTAssertEqual(count, 1)
        bridge.register(id) { count += 1 }; XCTAssertEqual(count, 1)
        bridge.finish(id); XCTAssertEqual(count, 2)
    }
    func testStoredKeysAreScopedAndNetworkPreparationBypassesReplay() async throws {
        let cached = Data(repeating: 1, count: 16), current = Data(repeating: 2, count: 16)
        let server = try LocalFixtureServer(files: ["/test.key": current])
        try await server.start(); defer { server.stop() }
        let url = server.baseURL.appendingPathComponent("test.key")
        let handle = StoredKeyURLProtocol.activate([url.absoluteString: cached])
        defer { StoredKeyURLProtocol.deactivate(handle) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.protocolClasses = [StoredKeyURLProtocol.self] + (configuration.protocolClasses ?? [])
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (saved, _) = try await session.data(from: url)
        XCTAssertEqual(saved, cached); XCTAssertEqual(server.requestCount, 0)
        XCTAssertEqual(StoredKeyURLProtocol.responseCount(handle), 1)
        let request = NSMutableURLRequest(url: url)
        StoredKeyURLProtocol.permitNetwork(request)
        let (fresh, _) = try await session.data(for: request as URLRequest)
        XCTAssertEqual(fresh, current); XCTAssertGreaterThan(server.requestCount, 0)
        StoredKeyURLProtocol.deactivate(handle)
        let (afterClose, _) = try await session.data(from: url)
        XCTAssertEqual(afterClose, current)
    }
    func testWatchResumeAndDeletingDuringPlaybackDoesNotRecreateRecord() {
        let name = "watch.test.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WatchStore(defaults: defaults)
        store.begin(selection); store.save(selection, position: 30, duration: 100)
        XCTAssertEqual(WatchStore(defaults: defaults).resumePosition(selection), 30)
        store.remove(selection.work.id); store.save(selection, position: 40, duration: 100)
        XCTAssertTrue(store.records.isEmpty)
        store.begin(selection); store.save(selection, position: 98, duration: 100)
        XCTAssertEqual(store.resumePosition(selection), 0)
    }
    func testPlaybackActuallySeeksToSavedPosition() async throws {
        let name = "resume.test.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let watch = WatchStore(defaults: defaults), model = PlaybackModel()
        watch.save(selection, position: 4, duration: 20)
        await model.load(selection, service: FixtureCatalogService(), watch: watch)
        try await wait({ model.ready && model.position >= 4.5 }, timeout: 10)
        XCTAssertLessThan(model.position, 10)
        model.stop(); XCTAssertGreaterThanOrEqual(watch.records.first?.position ?? 0, 4.5)
    }
    func testNextEpisodeStaysOnSelectedLine() async throws {
        let service = FixtureCatalogService()
        let known = try await service.episodes(10, line: "xl", page: 1).items
        let next = try await EpisodeNavigator.next(after: selection, known: known, total: 2, service: service)
        XCTAssertEqual(next?.episode.key, "2"); XCTAssertEqual(next?.lineKey, "xl")
        let end = try await EpisodeNavigator.next(after: next!, known: known, total: 2, service: service)
        XCTAssertNil(end)
        let unknownTotal = try await EpisodeNavigator.next(after: selection, known: [], total: 0, service: service)
        XCTAssertEqual(unknownTotal?.episode.key, "2")
    }
    func testUnreadableMetadataIsNotOverwritten() throws {
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("tasks.json"), bytes = Data("broken-metadata".utf8)
        try bytes.write(to: path)
        let center = DownloadCenter(root: root)
        XCTAssertNotNil(center.storageError); XCTAssertEqual(center.enqueue([selection]), 0)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
}
@MainActor final class PlayerTestSurface {
    let window: UIWindow
    let layer: AVPlayerLayer
    init(player: AVPlayer) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        let controller = UIViewController()
        window.rootViewController = controller
        layer = AVPlayerLayer(player: player)
        layer.frame = window.bounds
        controller.view.layer.addSublayer(layer)
        window.makeKeyAndVisible()
    }
    func close() { layer.player = nil; window.isHidden = true }
}
@MainActor private final class DownloadTestService: CatalogService {
    let sources: [PlaybackSource]
    var playbackCalls = 0, downloadCalls = 0
    init(sources: [PlaybackSource]) { self.sources = sources }
    func downloadSource(_ selection: MediaSelection) async throws -> PlaybackSource {
        let index = min(downloadCalls, sources.count - 1); downloadCalls += 1; return sources[index]
    }
    func playback(_ selection: MediaSelection) async throws -> PlaybackSource { playbackCalls += 1; throw CatalogError.invalidRequest }
    func search(_ query: String, page: Int) async throws -> [VideoWork] { throw CatalogError.invalidRequest }
    func detail(_ id: Int64) async throws -> VideoWork { throw CatalogError.invalidRequest }
    func manifest(_ id: Int64) async throws -> PlaybackManifest { throw CatalogError.invalidRequest }
    func episodes(_ id: Int64, line: String, page: Int) async throws -> EpisodeResponse { throw CatalogError.invalidRequest }
}
