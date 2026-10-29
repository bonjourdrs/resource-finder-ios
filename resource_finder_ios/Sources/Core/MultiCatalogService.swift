import Foundation

@MainActor final class MultiCatalogService: CatalogService {
    let access: ProviderAccessStore
    private let primary: any CatalogService
    private let providers: [String: PublicCatalogProvider]
    private var pages: [String: Bool] = [:]
    private var activeQuery = ""
    init(primary: any CatalogService, access: ProviderAccessStore? = nil) {
        self.primary = primary; self.access = access ?? .shared
        providers = Dictionary(uniqueKeysWithValues: ProviderRegistry.all.filter { $0.id != "jianpian" }.map { ($0.id, PublicCatalogProvider(config: $0)) })
    }
    private func searchRaw(_ id: String, query: String, page: Int) async throws -> ProviderSearch {
        if id == "jianpian" {
            let works = try await primary.search(query, page: page)
            return ProviderSearch(works: works, more: works.count >= 24 && page < 5)
        }
        guard let provider = providers[id] else { throw CatalogError.invalidRequest }
        return try await provider.search(query, page: page)
    }
    private func searchOne(_ id: String, query: String, page: Int) async throws -> ProviderSearch {
        do {
            let result = try await withThrowingTaskGroup(of: ProviderSearch.self) { group in
                group.addTask { @MainActor in try await self.searchRaw(id, query: query, page: page) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw CatalogError.message("来源检索超时，可单独重试")
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw CancellationError() }
                return value
            }
            try Task.checkCancellation(); access.catalog(id, query: query, count: result.works.count)
            return result
        } catch {
            if Task.isCancelled { throw CancellationError() }
            access.catalog(id, query: query, error: error); throw error
        }
    }
    func probe(_ id: String, query: String) async throws { _ = try await searchOne(id, query: query, page: 1) }
    func search(_ query: String, page: Int) async throws -> [VideoWork] {
        if page == 1 { pages = [:]; activeQuery = query }
        let ids = ProviderRegistry.all.map(\.id).filter { access.enabled($0) && (page == 1 || pages[$0] == true) }
        guard !ids.isEmpty else { if page == 1 { throw CatalogError.message("未启用影视来源，请到设置开启") }; return [] }
        let values = await withTaskGroup(of: (String, [VideoWork], Bool, Bool).self) { group in
            for id in ids {
                group.addTask { @MainActor in
                    do { let result = try await self.searchOne(id, query: query, page: page); return (id, result.works, result.more, true) }
                    catch { return (id, [], false, false) }
                }
            }
            var all: [(String, [VideoWork], Bool, Bool)] = []
            for await value in group { all.append(value) }
            return all
        }
        try Task.checkCancellation()
        guard activeQuery == query else { throw CancellationError() }
        var results: [VideoWork] = [], success = false
        for (id, works, more, ok) in values { pages[id] = more && page < (id == "jianpian" ? 5 : 3); results += works; success = success || ok }
        guard success else { throw CatalogError.message("本次各来源检索未成功，可到设置查看原因或重试") }
        var seen = Set<String>()
        return results.filter { seen.insert($0.sourceKey).inserted }.sorted { $0.sourceName < $1.sourceName }
    }
    func hasMore(page: Int, lastCount: Int) -> Bool { pages.values.contains(true) }
    func detail(_ id: Int64) async throws -> VideoWork { try await primary.detail(id) }
    func manifest(_ id: Int64) async throws -> PlaybackManifest { try await primary.manifest(id) }
    func episodes(_ id: Int64, line: String, page: Int) async throws -> EpisodeResponse { try await primary.episodes(id, line: line, page: page) }
    func detail(_ work: VideoWork) async throws -> VideoWork {
        if work.providerID == "jianpian" { return try await primary.detail(work.id) }
        guard let provider = providers[work.providerID] else { throw CatalogError.invalidRequest }
        return try await provider.work(work.id).work
    }
    func manifest(_ work: VideoWork) async throws -> PlaybackManifest {
        if work.providerID == "jianpian" { return try await primary.manifest(work.id) }
        guard let provider = providers[work.providerID] else { throw CatalogError.invalidRequest }
        let result = try await provider.work(work.id)
        return PlaybackManifest(workID: work.id, lines: result.lines.map(\.line))
    }
    func episodes(_ work: VideoWork, line: String, page: Int) async throws -> EpisodeResponse {
        if work.providerID == "jianpian" { return try await primary.episodes(work.id, line: line, page: page) }
        guard page > 0, let provider = providers[work.providerID], let selected = try await provider.work(work.id).lines.first(where: { $0.line.key == line }) else { throw CatalogError.invalidRequest }
        return EpisodeResponse(items: Array(selected.episodes.dropFirst((page - 1) * 100).prefix(100)).map(\.episode), total: selected.episodes.count)
    }
    func refresh(_ work: VideoWork) { if work.providerID == "jianpian" { primary.refresh(work) } else { providers[work.providerID]?.invalidate(work.id) } }
    func playback(_ selection: MediaSelection) async throws -> PlaybackSource {
        do {
            let source: PlaybackSource
            if selection.work.providerID == "jianpian" { source = try await primary.playback(selection) }
            else if let provider = providers[selection.work.providerID] { source = try await provider.resolve(selection) }
            else { throw CatalogError.invalidRequest }
            try Task.checkCancellation(); access.media(selection); return source
        } catch { if Task.isCancelled { throw CancellationError() }; access.media(selection, error: error); throw error }
    }
}
