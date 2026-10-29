import XCTest
import AVFoundation
@testable import ResourceFinder

@MainActor final class CoreTests: XCTestCase {
    private let crypto = JianpianCrypto(installationID: "00000000-0000-4000-8000-000000000001", credential: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    private let context = JPRequestContext(method: "GET", uri: "/api/v1/search?q=%E4%B8%89%E4%BD%93&page=1&__jp_crypto_request=fixture", timestamp: 1793070000, nonce: "AAECAwQFBgcICQoL")
    func testSignatureMatchesIndependentPythonVector() {
        XCTAssertEqual(crypto.signature(context, body: Data()), "b97zoy9ViCtMsJwpS0k6tlJGEoseWrCakm_Eip2S8nU")
    }
    func testNormalGuestIdentitySurvivesReload() throws {
        let first = try GuestIdentity.load(), second = try GuestIdentity.load()
        XCTAssertEqual(first.installationID, second.installationID)
        XCTAssertEqual(first.credential, second.credential)
        XCTAssertEqual(try JianpianCrypto.decode(first.credential).count, 32)
    }
    func testAuthenticatedResponseMatchesIndependentVector() throws {
        let data = try crypto.decryptResponse(context, status: 200, nonce: "DA0ODxAREhMUFRYX", data: "yxJW9lGrJWbqpb0q_P2Z3xrzQIHrVpA8KI1M44j7Bs1ZnkCZMD0zP4bkcz1Z3Kw_Wpo")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"found\":1,\"items\":[{\"id\":53488}]}")
    }
    func testResponseCannotBeReusedWithAnotherStatus() {
        XCTAssertThrowsError(try crypto.decryptResponse(context, status: 201, nonce: "DA0ODxAREhMUFRYX", data: "yxJW9lGrJWbqpb0q_P2Z3xrzQIHrVpA8KI1M44j7Bs1ZnkCZMD0zP4bkcz1Z3Kw_Wpo"))
    }
    func testPostEncryptionMatchesIndependentPythonVector() throws {
        let request = JPRequestContext(method: "POST", uri: "/api/v1/media/access", timestamp: context.timestamp, nonce: context.nonce)
        let plaintext = Data("{\"work_id\":53488,\"episode_key\":\"1\",\"episode_index\":0,\"preferred_line_key\":\"changzhangm3u8\",\"delivery_type\":\"playback\"}".utf8)
        XCTAssertEqual(try crypto.encryptRequest(request, plaintext: plaintext), "H42zWVqHajrMrIhwc1oI_ns4dHaS5YLwdl5__QaO5dRrkvv-rIneQB1QjwngViYlSQzgK_GjBt7E_QF3tJxMuu_4dQfvjeC9fn5FbmwVvr5x7et_sjvAHntdJXAxmwH-N7p2Cql-z7iK4E_qUjLW1T21u5AlJF0oPSw08-PP6mT6a1kcugg")
    }
    func testEncodedURIUsesExactEscapedQueryAndRejectsOtherRoutes() throws {
        XCTAssertEqual(try JianpianClient.encodedURI(path: "search", query: [("q", "三体 &+"), ("page", "1")]), "/api/v1/search?q=%E4%B8%89%E4%BD%93%20%26%2B&page=1")
        XCTAssertThrowsError(try JianpianClient.encodedURI(path: "../search", query: []))
        XCTAssertThrowsError(try JianpianClient.encodedURI(path: "works/0", query: []))
    }
    private var selection: MediaSelection {
        MediaSelection(work: VideoWork(id: 10, title: "fixture"), episode: VideoEpisode(key: "1", index: 0, name: "第1集"), lineKey: "xl")
    }
    private func descriptor(line: String = "xl", episode: String = "1", fallback: Bool = false, url: String = "https://media.example/video.m3u8", headers: [String: String] = [:]) -> MediaDescriptor {
        MediaDescriptor(url: url, protocolName: "hls", headers: headers, episodeKey: episode, line: .init(key: line), fallback: fallback)
    }
    func testMediaMustMatchSelectedEpisodeAndLine() throws {
        XCTAssertEqual(try descriptor().validated(for: selection).scheme, "https")
        XCTAssertThrowsError(try descriptor(line: "cz").validated(for: selection))
        XCTAssertThrowsError(try descriptor(episode: "2").validated(for: selection))
        XCTAssertThrowsError(try descriptor(fallback: true).validated(for: selection))
    }
    func testProprietaryMediaSchemesAreRejected() {
        XCTAssertThrowsError(try descriptor(url: "jianpian://fixture").validated(for: selection))
        XCTAssertThrowsError(try descriptor(url: "file:///private/fixture").validated(for: selection))
    }
    func testRequiredMediaHeadersAreNotSilentlyDropped() throws {
        XCTAssertEqual(try descriptor(headers: ["User-Agent": "fixture", "X-JP-Nonce": "excluded"]).userAgent(), "fixture")
        XCTAssertEqual(try descriptor(headers: ["Referer": "https://example.com"]).mediaHeaders()["Referer"], "https://example.com")
        XCTAssertThrowsError(try descriptor(headers: ["Referer": "bad\r\ninjection"]).mediaHeaders())
    }
    func testSearchDeletionPersistsAndDoesNotAffectFavorites() {
        let suite = "rf.tests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults)
        store.record("三体"); store.record("测试"); store.record("三体")
        XCTAssertEqual(store.searches, ["三体", "测试"])
        store.toggleFavorite(selection.work); store.removeSearches(at: IndexSet(integer: 0))
        XCTAssertEqual(LibraryStore(defaults: defaults).searches, ["测试"])
        store.clearSearches()
        XCTAssertTrue(LibraryStore(defaults: defaults).searches.isEmpty)
        XCTAssertEqual(LibraryStore(defaults: defaults).favorites.map(\.id), [10])
    }
    func testSameTitleWorksHaveSeparateFavorites() {
        let suite = "rf.tests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults)
        store.toggleFavorite(VideoWork(id: 1, title: "同名")); store.toggleFavorite(VideoWork(id: 2, title: "同名"))
        XCTAssertEqual(Set(LibraryStore(defaults: defaults).favorites.map(\.id)), [1, 2])
    }
    func testSameNumericWorkAcrossSourcesKeepsIndependentFavoritesAndHistory() throws {
        let suite = "rf.cross-source.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let jp = selection
        var otherWork = jp.work; otherWork.sourceID = "kkys"
        let kkys = MediaSelection(work: otherWork, episode: jp.episode, lineKey: jp.lineKey)
        let library = LibraryStore(defaults: defaults), history = WatchStore(defaults: defaults)
        library.toggleFavorite(jp.work); library.toggleFavorite(kkys.work)
        XCTAssertEqual(Set(library.favorites.map(\.sourceKey)), ["jp:10", "kkys:10"])
        library.toggleFavorite(jp.work)
        XCTAssertTrue(LibraryStore(defaults: defaults).isFavorite(kkys.work))
        history.save(jp, position: 10, duration: 100); history.save(kkys, position: 20, duration: 100)
        XCTAssertEqual(WatchStore(defaults: defaults).records.count, 2)
        history.remove(jp.work.sourceKey); history.save(jp, position: 30, duration: 100)
        history.save(kkys, position: 40, duration: 100)
        XCTAssertEqual(history.records.map(\.id), ["kkys:10"])
        XCTAssertEqual(history.resumePosition(kkys), 40)
        XCTAssertNotEqual(jp.id, kkys.id)
    }
    func testChangingLinesReloadsTheirOwnEpisodes() async {
        let model = DetailModel(work: FixtureCatalogService.work, service: FixtureCatalogService())
        await model.load(); await model.loadEpisodes(reset: true)
        XCTAssertEqual(model.episodes.map(\.key), ["1", "2"])
        XCTAssertFalse(model.lines.first { $0.key == "vip" }!.available)
        model.selectedLine = "cz"; await model.loadEpisodes(reset: true)
        XCTAssertEqual(model.episodes.map(\.key), ["special"])
        XCTAssertEqual(model.selection(model.episodes[0])?.lineKey, "cz")
    }
    func testSyntheticVideoDecodesAndPlaybackAdvancesThenReleases() async throws {
        let url = try FixtureCatalogService.fixtureURL()
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try generator.copyCGImage(at: .zero, actualTime: nil)
        XCTAssertEqual(image.width, 320); XCTAssertEqual(image.height, 180)
        let model = PlaybackModel()
        await model.load(selection, service: FixtureCatalogService())
        for _ in 0..<60 {
            if model.ready && model.position >= 0.5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(model.ready); XCTAssertGreaterThanOrEqual(model.position, 0.5); XCTAssertNil(model.error)
        model.stop(); XCTAssertNil(model.player.currentItem)
    }
    func testOlderSearchCannotOverwriteNewerResults() async throws {
        let suite = "rf.tests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SearchModel(service: DelayedCatalog())
        let store = LibraryStore(defaults: defaults)
        model.query = "旧搜索"; model.search(store: store)
        try await Task.sleep(for: .milliseconds(10))
        model.query = "新搜索"; model.search(store: store)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.results.map(\.title), ["新搜索"])
    }
}
@MainActor private final class DelayedCatalog: CatalogService {
    func search(_ query: String, page: Int) async throws -> [VideoWork] {
        // Simulate an upstream that completes even after cancellation.
        if query == "旧搜索" { try? await Task.sleep(for: .milliseconds(250)) }
        return [VideoWork(id: query == "旧搜索" ? 1 : 2, title: query)]
    }
    func detail(_ id: Int64) async throws -> VideoWork { throw CatalogError.invalidRequest }
    func manifest(_ id: Int64) async throws -> PlaybackManifest { throw CatalogError.invalidRequest }
    func episodes(_ id: Int64, line: String, page: Int) async throws -> EpisodeResponse { throw CatalogError.invalidRequest }
    func playback(_ selection: MediaSelection) async throws -> PlaybackSource { throw CatalogError.invalidRequest }
}
