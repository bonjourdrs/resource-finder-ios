import Foundation
import XCTest
@testable import ProviderCore

final class ProviderTests: XCTestCase {
    @MainActor func testSameNumericWorkAcrossSourcesKeepsIndependentFavoritesAndHistory() throws {
        let suite = "rf.cross-source.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let jp = MediaSelection(work: VideoWork(id: 10, title: "样本"), episode: VideoEpisode(key: "1", index: 0, name: "第1集"), lineKey: "l")
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
    private var config: ProviderConfig { ProviderRegistry.config("hongniu")! }
    private func body(_ groups: String, flags: String = "native", id: Int = 7) throws -> String {
        let root: [String: Any] = ["code": 1, "list": [["vod_id": id, "vod_name": "样本", "vod_play_from": flags, "vod_play_url": groups]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }
    func testLegacyIdentityAndCodableRemainCompatible() throws {
        let old = #"{"work":{"id":7,"title":"A"},"episode":{"key":"1","index":0,"name":"第1集"},"lineKey":"xl"}"#
        let selection = try JSONDecoder().decode(MediaSelection.self, from: Data(old.utf8))
        XCTAssertEqual(selection.work.providerID, "jianpian"); XCTAssertEqual(selection.id, "jp:7:xl:1")
        var other = selection.work; other.sourceID = "kkys"
        XCTAssertNotEqual(other.sourceKey, selection.work.sourceKey)
        XCTAssertEqual(selection, try JSONDecoder().decode(MediaSelection.self, from: JSONEncoder().encode(selection)))
    }
    func testCatalogPaginationAndIdentity() throws {
        let json = #"{"code":1,"pagecount":"2","list":[{"vod_id":7,"vod_name":"A &amp; B","vod_year":"2023"}]}"#
        let first = try PublicCatalogParser.searchJSON(json, config: config, page: 1)
        XCTAssertEqual(first.works.first?.sourceKey, "hongniu:7"); XCTAssertEqual(first.works.first?.title, "A & B"); XCTAssertTrue(first.more)
        XCTAssertFalse(try PublicCatalogParser.searchJSON(json, config: config, page: 2).more)
        XCTAssertThrowsError(try PublicCatalogParser.searchJSON(#"{"code":1}"#, config: config, page: 1))
    }
    func testUnsupportedGroupsAndAliasesAreRetained() throws {
        let group = "第01集$https://cdn.example/a.m3u8"
        let work = try PublicCatalogParser.detailJSON(body(group + "$$$" + group + "$$$" + "正片$https://cloud.example/player?id=7" + "$$$", flags: "a$$$b$$$cloud$$$empty"), config: config, id: 7)
        XCTAssertEqual(work.lines.count, 4)
        XCTAssertNotEqual(work.lines[0].line.key, work.lines[1].line.key)
        XCTAssertNotNil(work.lines[2].line.unsupportedReason); XCTAssertNotNil(work.lines[3].line.unsupportedReason)
        XCTAssertNil(work.lines[2].episodes.first?.kind)
    }
    func testSupportedIDsSurviveURLRefreshAndUnsupportedInsertion() throws {
        let old = try PublicCatalogParser.detailJSON(body("第01集$https://cdn.example/a.m3u8?old=1"), config: config, id: 7)
        let fresh = try PublicCatalogParser.detailJSON(body("第01集$https://cloud.example/p#第01集$https://cdn.example/a.m3u8?new=1"), config: config, id: 7)
        XCTAssertEqual(old.lines[0].episodes[0].episode.key, fresh.lines[0].episodes[1].episode.key)
        XCTAssertNotEqual(fresh.lines[0].episodes[0].episode.key, fresh.lines[0].episodes[1].episode.key)
        XCTAssertThrowsError(try PublicCatalogParser.detailJSON(body("HD$https://cdn.example/a.m3u8", id: 8), config: config, id: 7))
    }
    func testNativeHintsAndPrivateURLs() throws {
        let work = try PublicCatalogParser.detailJSON(body("第01集$https://cdn.example/stream?id=7", flags: "ffm3u8"), config: config, id: 7)
        XCTAssertEqual(work.lines[0].episodes[0].kind, .hls)
        XCTAssertNil(PublicCatalogParser.nativeKind("https://u:p@cdn.example/a.m3u8"))
        XCTAssertNil(PublicCatalogParser.nativeKind("https://127.0.0.1/a.m3u8"))
        XCTAssertNil(PublicCatalogParser.nativeKind("https://cloud.example/player?url=https://x.example/a.m3u8"))
    }
    func testKKYSVariantsAndEpisodeNumbers() throws {
        let html = #"<h1>样本</h1><div class="source-item">DB</div><div class="source-item">DB备用</div><div class="episode-list"><a href="/play/7-37-1.html">HD国语</a><a href="/play/7-37-2.html">第01集</a><a href="/play/8-37-9.html">串片</a></div><div class="episode-list"><a href="/play/7-37-3.html">第01集</a></div>"#
        let work = try PublicCatalogParser.detailKKYS(html, base: URL(string: "https://catalog.example/detail/7.html")!, id: 7)
        XCTAssertEqual(work.lines.count, 2); XCTAssertNotEqual(work.lines[0].line.key, work.lines[1].line.key)
        XCTAssertEqual(work.lines[0].episodes.count, 2); XCTAssertNil(work.lines[0].episodes[0].episode.number); XCTAssertEqual(work.lines[0].episodes[1].episode.number, 1)
    }
    func testKKYSSearchAndDataOnlyMedia() throws {
        let base = URL(string: "https://catalog.example/search")!
        let html = #"<a class="search-result-item" href="/detail/7.html"><div class="title">影片</div><div class="tags"><span>2020</span></div><img data-original="/a.jpg"></a>"#
        let found = try PublicCatalogParser.searchKKYS(html, base: base)
        XCTAssertEqual(found.works.first?.sourceKey, "kkys:7"); XCTAssertEqual(found.works.first?.year, 2020)
        let media = try PublicCatalogParser.mediaKKYS(#"const playSource={src:"//cdn.example/a.m3u8?x=1\u0026y=2",type:"application/x-mpegURL"}; throw Error('never execute');"#, base: base)
        XCTAssertEqual(media.url.absoluteString, "https://cdn.example/a.m3u8?x=1&y=2")
        XCTAssertThrowsError(try PublicCatalogParser.mediaKKYS(#"const playSource={src:"",type:"application/x-mpegURL"};"#, base: base))
    }
    func testManifestPolicyRejectsPlaceholdersAndUnsupportedCrypto() throws {
        let base = URL(string: "https://cdn.example/a/list.m3u8")!
        XCTAssertThrowsError(try ProviderHLS.inspect("#EXTM3U\n#EXTINF:2,\na.ts\n#EXTINF:2,\nb.ts\n#EXT-X-ENDLIST", base: base))
        XCTAssertThrowsError(try ProviderHLS.inspect("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXTINF:30,\na.ts", base: base))
        XCTAssertThrowsError(try ProviderHLS.inspect("#EXTM3U\n#EXTINF:nan,\na.ts\n#EXT-X-ENDLIST", base: base))
        let master = try ProviderHLS.inspect("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n../v.m3u8", base: base)
        XCTAssertEqual(master.variants.first?.absoluteString, "https://cdn.example/v.m3u8")
        XCTAssertEqual(try ProviderHLS.inspect("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\",KEYFORMAT=\"identity\"\n#EXTINF:30,\na.ts\n#EXT-X-ENDLIST", base: base).seconds, 30)
    }
    @MainActor func testFailedAndUntestedSourcesKeepUserChoiceAndIndependentStates() throws {
        let name = "provider.tests.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ProviderAccessStore(defaults: defaults)
        XCTAssertEqual(ProviderRegistry.all.count, 10); XCTAssertEqual(ProviderRegistry.all.filter(\.experimental).count, 5)
        XCTAssertTrue(store.enabled("feifan")); XCTAssertEqual(store.observation("feifan").catalog.state, .unverified)
        let selection = MediaSelection(work: VideoWork(id: 7, title: "A", sourceID: "feifan"), episode: VideoEpisode(key: "e", index: 0, name: "HD"), lineKey: "l")
        store.media(selection, error: CatalogError.http(403)); store.catalog("feifan", query: "A", count: 1)
        XCTAssertTrue(store.enabled("feifan")); XCTAssertEqual(store.observation("feifan").catalog.state, .resolved); XCTAssertEqual(store.observation("feifan").media.state, .failed)
        store.setEnabled("feifan", false); store.media(selection)
        let restored = ProviderAccessStore(defaults: defaults)
        XCTAssertFalse(restored.enabled("feifan")); XCTAssertEqual(restored.observation("feifan").media.state, .resolved)
    }
    @MainActor func testNextEpisodeRefusesGapsAndAmbiguity() async throws {
        let work = VideoWork(id: 7, title: "A", sourceID: "kkys")
        let one = VideoEpisode(key: "one", index: 0, name: "第01集", number: 1), two = VideoEpisode(key: "two", index: 1, name: "第02集", number: 2), three = VideoEpisode(key: "three", index: 2, name: "第03集", number: 3)
        let selected = MediaSelection(work: work, episode: one, lineKey: "l"), service = EmptyCatalog()
        let missing = try await EpisodeNavigator.next(after: selected, known: [one, three], total: 2, service: service)
        XCTAssertNil(missing)
        let next = try await EpisodeNavigator.next(after: selected, known: [one, three, two], total: 3, service: service)
        XCTAssertEqual(next?.episode.number, 2)
        let ambiguous = try await EpisodeNavigator.next(after: selected, known: [one, two, VideoEpisode(key: "duplicate", index: 3, name: "2", number: 2)], total: 3, service: service)
        XCTAssertNil(ambiguous)
    }
}
@MainActor final class EmptyCatalog: CatalogService {
    func search(_ query: String, page: Int) async throws -> [VideoWork] { [] }
    func detail(_ id: Int64) async throws -> VideoWork { throw CatalogError.invalidRequest }
    func manifest(_ id: Int64) async throws -> PlaybackManifest { throw CatalogError.invalidRequest }
    func episodes(_ id: Int64, line: String, page: Int) async throws -> EpisodeResponse { EpisodeResponse(items: [], total: 0) }
    func playback(_ selection: MediaSelection) async throws -> PlaybackSource { throw CatalogError.unsupportedMedia }
}

final class PlaybackPolicyTests: XCTestCase {
    func testAutoHideAndAndroidSpeedContract() {
        XCTAssertEqual(PlaybackPolicy.speeds, [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3])
        XCTAssertEqual(PlaybackPolicy.hideDelay, 3)
        XCTAssertTrue(PlaybackPolicy.canHide(playing: true, locked: false, panel: false, interacting: false))
        XCTAssertTrue(PlaybackPolicy.canHide(playing: false, locked: true, panel: false, interacting: false))
        XCTAssertFalse(PlaybackPolicy.canHide(playing: false, locked: false, panel: false, interacting: false))
        XCTAssertFalse(PlaybackPolicy.canHide(playing: true, locked: false, panel: true, interacting: false))
        XCTAssertFalse(PlaybackPolicy.canHide(playing: true, locked: false, panel: false, interacting: true))
    }
    func testLineSwitchRequiresTheSameEpisodeAndRefusesAmbiguity() {
        let current = MediaSelection(work: VideoWork(id: 7, title: "A", sourceID: "kkys"), episode: VideoEpisode(key: "old", index: 0, name: "第01集", number: 1), lineKey: "a")
        let same = VideoEpisode(key: "new", index: 8, name: "第1集", number: 1), wrong = VideoEpisode(key: "wrong", index: 0, name: "第2集", number: 2)
        XCTAssertEqual(PlaybackPolicy.matching(current, in: [wrong, same]), same)
        XCTAssertNil(PlaybackPolicy.matching(current, in: [wrong]))
        XCTAssertNil(PlaybackPolicy.matching(current, in: [same, VideoEpisode(key: "dup", index: 3, name: "1", number: 1)]))
        let jp = MediaSelection(work: VideoWork(id: 7, title: "A"), episode: current.episode, lineKey: "a")
        XCTAssertNil(PlaybackPolicy.matching(jp, in: [same]))
        XCTAssertEqual(PlaybackPolicy.matching(jp, in: [current.episode]), current.episode)
    }
    func testMovieLineMatchingUsesUniqueNameThenUniqueMovie() {
        let selected = MediaSelection(work: VideoWork(id: 7, title: "A", sourceID: "kkys"), episode: VideoEpisode(key: "old", index: 0, name: "HD国语"), lineKey: "a")
        let mandarin = VideoEpisode(key: "a", index: 1, name: "HD国语"), cantonese = VideoEpisode(key: "b", index: 0, name: "HD粤语")
        XCTAssertEqual(PlaybackPolicy.matching(selected, in: [cantonese, mandarin]), mandarin)
        XCTAssertEqual(PlaybackPolicy.matching(selected, in: [cantonese]), cantonese)
        XCTAssertNil(PlaybackPolicy.matching(selected, in: [cantonese, cantonese]))
    }
}
