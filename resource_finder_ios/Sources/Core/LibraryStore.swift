import Foundation
#if canImport(Combine)
import Combine
#endif

@MainActor final class LibraryStore {
    #if canImport(Combine)
    @Published private(set) var searches: [String]
    @Published private(set) var favorites: [VideoWork]
    #else
    private(set) var searches: [String]
    private(set) var favorites: [VideoWork]
    #endif
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        searches = (try? JSONDecoder().decode([String].self, from: defaults.data(forKey: "searches.v1") ?? Data())) ?? []
        favorites = (try? JSONDecoder().decode([VideoWork].self, from: defaults.data(forKey: "favorites.v1") ?? Data())) ?? []
    }
    func record(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searches.removeAll { $0 == value }
        searches.insert(value, at: 0)
        searches = Array(searches.prefix(50))
        persist()
    }
    func removeSearches(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where searches.indices.contains(index) { searches.remove(at: index) }
        persist()
    }
    func clearSearches() { searches.removeAll(); persist() }
    func isFavorite(_ work: VideoWork) -> Bool { favorites.contains { $0.sourceKey == work.sourceKey } }
    func toggleFavorite(_ work: VideoWork) {
        if isFavorite(work) { favorites.removeAll { $0.sourceKey == work.sourceKey } }
        else { favorites.insert(work, at: 0) }
        persist()
    }
    private func persist() {
        defaults.set(try? JSONEncoder().encode(searches), forKey: "searches.v1")
        defaults.set(try? JSONEncoder().encode(favorites), forKey: "favorites.v1")
    }
}

#if canImport(Combine)
extension LibraryStore: ObservableObject {}
#endif
