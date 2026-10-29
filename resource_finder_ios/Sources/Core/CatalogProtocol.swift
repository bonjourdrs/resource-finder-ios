import Foundation

@MainActor protocol CatalogService {
    func search(_ query: String, page: Int) async throws -> [VideoWork]
    func detail(_ id: Int64) async throws -> VideoWork
    func manifest(_ id: Int64) async throws -> PlaybackManifest
    func episodes(_ id: Int64, line: String, page: Int) async throws -> EpisodeResponse
    func detail(_ work: VideoWork) async throws -> VideoWork
    func manifest(_ work: VideoWork) async throws -> PlaybackManifest
    func episodes(_ work: VideoWork, line: String, page: Int) async throws -> EpisodeResponse
    func refresh(_ work: VideoWork)
    func hasMore(page: Int, lastCount: Int) -> Bool
    func playback(_ selection: MediaSelection) async throws -> PlaybackSource
    func downloadSource(_ selection: MediaSelection) async throws -> PlaybackSource
}
extension CatalogService {
    func detail(_ work: VideoWork) async throws -> VideoWork { try await detail(work.id) }
    func manifest(_ work: VideoWork) async throws -> PlaybackManifest { try await manifest(work.id) }
    func episodes(_ work: VideoWork, line: String, page: Int) async throws -> EpisodeResponse { try await episodes(work.id, line: line, page: page) }
    func refresh(_ work: VideoWork) {}
    func hasMore(page: Int, lastCount: Int) -> Bool { lastCount >= 24 && page < 5 }
    func downloadSource(_ selection: MediaSelection) async throws -> PlaybackSource { try await playback(selection) }
}
