import Foundation

@MainActor enum EpisodeNavigator {
    static func next(after selection: MediaSelection, known: [VideoEpisode], total: Int, service: any CatalogService) async throws -> MediaSelection? {
        if selection.work.providerID != "jianpian" {
            guard let number = selection.episode.number else { return nil }
            var items = known
            if known.isEmpty || known.count < total || total == 0 {
                items = []; var seen = Set<String>(), loaded = 0
                for page in 1...100 {
                    let response = try await service.episodes(selection.work, line: selection.lineKey, page: page)
                    try Task.checkCancellation(); loaded += response.items.count
                    items += response.items.filter { seen.insert($0.key).inserted }
                    if response.items.isEmpty || loaded >= response.total { break }
                }
            }
            let candidates = items.filter { $0.number == number + 1 && $0.unsupportedReason == nil }
            guard candidates.count == 1, let next = candidates.first else { return nil }
            return MediaSelection(work: selection.work, episode: next, lineKey: selection.lineKey)
        }
        if let index = known.firstIndex(where: { $0.key == selection.episode.key }), index + 1 < known.count {
            return MediaSelection(work: selection.work, episode: known[index + 1], lineKey: selection.lineKey)
        }
        if total > 0, known.count >= total, !known.isEmpty { return nil }
        var found = false, seen = Set<String>(), loaded = 0
        for page in 1...100 {
            let response = try await service.episodes(selection.work, line: selection.lineKey, page: page)
            try Task.checkCancellation()
            for episode in response.items where seen.insert(episode.key).inserted {
                loaded += 1
                if found { return MediaSelection(work: selection.work, episode: episode, lineKey: selection.lineKey) }
                if episode.key == selection.episode.key { found = true }
            }
            if response.items.isEmpty || loaded >= response.total { break }
        }
        return nil
    }
}
