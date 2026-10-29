import XCTest
import AVFoundation
@testable import ResourceFinder

@MainActor final class PlayerParityTests: XCTestCase {
    private var selection: MediaSelection { MediaSelection(work: FixtureCatalogService.work, episode: .init(key: "1", index: 0, name: "第1集"), lineKey: "xl") }
    private func ready(_ model: PlaybackModel) async throws {
        for _ in 0..<100 { if model.ready && model.position > 0.2 { return }; try await Task.sleep(for: .milliseconds(100)) }
        XCTFail(model.error ?? "Video failed to advance")
    }
    func testTemporarySpeedRestoresFixedRateAfterReleasePauseAndReload() async throws {
        let suite = "rf.player.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlaybackModel(defaults: defaults); defer { model.stop() }
        await model.load(selection, service: FixtureCatalogService()); try await ready(model)
        model.setSpeed(1.25); model.hold(); XCTAssertTrue(model.holding); XCTAssertEqual(model.speed, 2)
        model.releaseHold(); XCTAssertFalse(model.holding); XCTAssertEqual(model.speed, 1.25)
        model.hold(); model.pause(); XCTAssertFalse(model.holding); XCTAssertEqual(model.speed, 1.25); XCTAssertFalse(model.playing)
        model.setSpeed(3); model.play(); model.hold(); XCTAssertEqual(model.speed, 3)
        model.stop(); XCTAssertEqual(PlaybackModel(defaults: defaults).speed, 3)
    }
    func testHeaderProtectedHLSActuallyDecodesThroughRelay() async throws {
        let server = try LocalFixtureServer(files: LocalFixtureServer.bundledFiles(), requiredHeaders: ["Referer": "https://fixture.example/"])
        try await server.start(); defer { server.stop() }
        let source = PlaybackSource(url: server.baseURL.appendingPathComponent("aes_index.m3u8"), kind: .hls, headers: ["Referer": "https://fixture.example/"])
        let service = SourceTestService(source: source), model = PlaybackModel()
        let surface = try PlayerTestSurface(player: model.player); defer { model.stop(); surface.close() }
        await model.load(selection, service: service)
        try await ready(model); XCTAssertNil(model.error); XCTAssertTrue(surface.layer.isReadyForDisplay)
        model.seek(3); model.play()
        for _ in 0..<50 { if model.position >= 3 { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertGreaterThanOrEqual(model.position, 3); XCTAssertGreaterThan(server.requestCount, 2)
    }
    func testRelayHonorsFileRangeAndRejectsUnknownRoute() async throws {
        let url = try FixtureCatalogService.fixtureURL(), relay = try MediaRelay(source: PlaybackSource(url: url, offline: true))
        let local = try await relay.start(); defer { relay.stop() }
        var request = URLRequest(url: local); request.setValue("bytes=2-11", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, try Data(contentsOf: url).subdata(in: 2..<12))
        let (_, denied) = try await URLSession.shared.data(from: local.deletingLastPathComponent().appendingPathComponent("unregistered.mp4"))
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404)
    }
}

@MainActor private final class SourceTestService: CatalogService {
    let source: PlaybackSource
    init(source: PlaybackSource) { self.source = source }
    func playback(_ selection: MediaSelection) async throws -> PlaybackSource { source }
    func search(_ query: String, page: Int) async throws -> [VideoWork] { [] }
    func detail(_ id: Int64) async throws -> VideoWork { throw CatalogError.invalidRequest }
    func manifest(_ id: Int64) async throws -> PlaybackManifest { throw CatalogError.invalidRequest }
    func episodes(_ id: Int64, line: String, page: Int) async throws -> EpisodeResponse { throw CatalogError.invalidRequest }
}
