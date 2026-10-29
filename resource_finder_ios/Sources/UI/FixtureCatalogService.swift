#if DEBUG
import Foundation

/// Deterministic, generated fixtures are enabled only by the UI-test launch flag.
/// Normal app launches always use LiveCatalogService and never fall back here.
@MainActor final class FixtureCatalogService: CatalogService {
    private var server: LocalFixtureServer?
    static let work = VideoWork(id: 10, title: "测试影片", year: 2026, kind: "电影", summary: "自动化检查使用的合成色块视频，不含真实影视内容。")
    func search(_ query: String, page: Int) async throws -> [VideoWork] {
        try await Task.sleep(for: .milliseconds(40))
        return page == 1 ? [Self.work] : []
    }
    func detail(_ id: Int64) async throws -> VideoWork { Self.work }
    func manifest(_ id: Int64) async throws -> PlaybackManifest {
        PlaybackManifest(workID: id, lines: [VideoLine(key: "xl", name: "XL 线路", episodeCount: 2, entitlementRequired: false),
                                            VideoLine(key: "cz", name: "CZ 线路", episodeCount: 1, entitlementRequired: false),
                                            VideoLine(key: "vip", name: "需授权线路", episodeCount: 1, entitlementRequired: true)])
    }
    func episodes(_ id: Int64, line: String, page: Int) async throws -> EpisodeResponse {
        try await Task.sleep(for: .milliseconds(40))
        let items = line == "xl" ? [VideoEpisode(key: "1", index: 0, name: "第1集"), VideoEpisode(key: "2", index: 1, name: "第2集")] : [VideoEpisode(key: "special", index: 0, name: "特别篇")]
        return EpisodeResponse(items: items, total: items.count)
    }
    func playback(_ selection: MediaSelection) async throws -> PlaybackSource {
        PlaybackSource(url: try Self.fixtureURL())
    }
    func downloadSource(_ selection: MediaSelection) async throws -> PlaybackSource {
        if server == nil { let value = try LocalFixtureServer(files: LocalFixtureServer.bundledFiles()); try await value.start(); server = value }
        return PlaybackSource(url: server!.baseURL.appendingPathComponent("video.mp4"))
    }
    static func fixtureURL() throws -> URL {
        guard let resource = Bundle.main.url(forResource: "playback.mp4", withExtension: "b64"),
              let data = Data(base64Encoded: try Data(contentsOf: resource), options: .ignoreUnknownCharacters) else { throw CatalogError.invalidResponse }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resource-finder-fixture.mp4")
        try data.write(to: url, options: .atomic)
        return url
    }
}
#endif
