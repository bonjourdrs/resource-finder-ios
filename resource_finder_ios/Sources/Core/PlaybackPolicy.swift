import Foundation

/// Shared product rules mirrored from the Android player. UI and transport stay native.
enum PlaybackPolicy {
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3]
    static let hideDelay: Double = 3
    static func canHide(playing: Bool, locked: Bool, panel: Bool, interacting: Bool) -> Bool {
        !panel && !interacting && (playing || locked)
    }
    static func matching(_ selection: MediaSelection, in items: [VideoEpisode]) -> VideoEpisode? {
        let items = items.filter { $0.unsupportedReason == nil }
        if selection.work.providerID == "jianpian" {
            return items.first { $0.key == selection.episode.key && $0.name == selection.episode.name }
        }
        if let number = selection.episode.number { return unique(items.filter { $0.number == number }) }
        let movies = items.filter { $0.number == nil }
        return unique(movies.filter { $0.name == selection.episode.name }) ?? unique(movies)
    }
    private static func unique(_ items: [VideoEpisode]) -> VideoEpisode? { items.count == 1 ? items.first : nil }
}

@MainActor enum PlaybackCatalog {
    static func episodes(_ selection: MediaSelection, line: String, service: any CatalogService) async throws -> [VideoEpisode] {
        var items: [VideoEpisode] = [], seen = Set<String>(), read = 0
        for page in 1...100 {
            let response = try await service.episodes(selection.work, line: line, page: page)
            try Task.checkCancellation(); read += response.items.count
            items += response.items.filter { seen.insert($0.key).inserted }
            if response.items.isEmpty || read >= response.total { return items }
        }
        throw CatalogError.message("剧集过多，请返回详情选择")
    }
}
