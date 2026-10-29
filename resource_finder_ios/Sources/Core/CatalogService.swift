import Foundation

@MainActor final class LiveCatalogService: CatalogService {
    let client: JianpianClient
    init(client: JianpianClient) { self.client = client }
    func search(_ query: String, page: Int) async throws -> [VideoWork] {
        let response: SearchResponse = try await client.request("search", query: [("q", query), ("page", String(page)), ("page_size", "24")])
        return response.items.filter { $0.id > 0 && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    func detail(_ id: Int64) async throws -> VideoWork {
        let result: VideoWork = try await client.request("works/\(id)")
        guard result.id == id else { throw CatalogError.invalidResponse }
        return result
    }
    func manifest(_ id: Int64) async throws -> PlaybackManifest {
        let result: PlaybackManifest = try await client.request("works/\(id)/playback-manifest")
        guard result.workID == id else { throw CatalogError.invalidResponse }
        return result
    }
    func episodes(_ id: Int64, line: String, page: Int) async throws -> EpisodeResponse {
        try await client.request("works/\(id)/episodes", query: [("line_key", line), ("page", String(page)), ("page_size", "100")])
    }
    func resolve(_ selection: MediaSelection) async throws -> MediaDescriptor {
        let body: [String: Any] = ["work_id": selection.work.id, "episode_key": selection.episode.key,
                                   "episode_index": selection.episode.index, "preferred_line_key": selection.lineKey, "delivery_type": "playback"]
        let response: MediaDescriptor = try await client.request("media/access", body: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        _ = try response.validated(for: selection)
        return response
    }
    func playback(_ selection: MediaSelection) async throws -> PlaybackSource {
        let descriptor = try await resolve(selection)
        return try PlaybackSource(url: descriptor.validated(for: selection), userAgent: descriptor.userAgent(), kind: descriptor.protocolName == "hls" ? .hls : .progressive, headers: descriptor.mediaHeaders().filter { $0.key.lowercased() != "user-agent" })
    }
}

@MainActor final class DeferredJianpianService: CatalogService {
    private var service: LiveCatalogService?
    private func live() throws -> LiveCatalogService {
        if let service { return service }
        let value = LiveCatalogService(client: JianpianClient(identity: try GuestIdentity.load()))
        service = value; return value
    }
    func search(_ query: String, page: Int) async throws -> [VideoWork] { try await live().search(query, page: page) }
    func detail(_ id: Int64) async throws -> VideoWork { try await live().detail(id) }
    func manifest(_ id: Int64) async throws -> PlaybackManifest { try await live().manifest(id) }
    func episodes(_ id: Int64, line: String, page: Int) async throws -> EpisodeResponse { try await live().episodes(id, line: line, page: page) }
    func playback(_ selection: MediaSelection) async throws -> PlaybackSource { try await live().playback(selection) }
}
