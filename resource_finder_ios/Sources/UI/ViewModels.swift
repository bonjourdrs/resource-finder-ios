import Foundation
import Combine

@MainActor final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [VideoWork] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var searched = false
    @Published private(set) var hasMore = false
    private let service: any CatalogService
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var submittedQuery = ""
    private var page = 0
    init(service: any CatalogService) { self.service = service }
    func search(store: LibraryStore) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        task?.cancel(); generation = UUID()
        submittedQuery = value; page = 0; results = []; hasMore = false; searched = true
        store.record(value)
        loadMore()
    }
    func loadMore() {
        guard page == 0 || (!loading && hasMore) else { return }
        let token = generation, requestedPage = page + 1, query = submittedQuery
        loading = true; error = nil
        task = Task {
            do {
                let part = try await service.search(query, page: requestedPage)
                try Task.checkCancellation()
                guard generation == token else { return }
                var ids = Set(results.map(\.sourceKey))
                results += part.filter { ids.insert($0.sourceKey).inserted }
                page = requestedPage; hasMore = service.hasMore(page: page, lastCount: part.count); loading = false
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
    }
}
@MainActor final class DetailModel: ObservableObject {
    @Published private(set) var work: VideoWork
    @Published private(set) var lines: [VideoLine] = []
    @Published var selectedLine: String?
    @Published private(set) var episodes: [VideoEpisode] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = true
    @Published private(set) var loadingEpisodes = false
    @Published private(set) var error: String?
    @Published private(set) var episodeError: String?
    private let service: any CatalogService
    @Published private(set) var lineChecks: [String: AccessObservation] = [:]
    @Published private(set) var checkingLine: String?
    private var page = 0
    private var episodeGeneration = UUID()
    init(work: VideoWork, service: any CatalogService) { self.work = work; self.service = service }
    func load(refresh: Bool = false) async {
        if refresh { service.refresh(work) }
        selectedLine = nil; episodes = []; total = 0; page = 0; episodeGeneration = UUID(); loadingEpisodes = false
        loading = true; error = nil
        do {
            let detail = try await service.detail(work)
            let manifest = try await service.manifest(work)
            try Task.checkCancellation()
            guard detail.sourceKey == work.sourceKey, manifest.workID == work.id else { throw CatalogError.invalidResponse }
            var merged = detail
            merged.year = detail.year ?? work.year; merged.kind = detail.kind?.isEmpty == false ? detail.kind : work.kind
            merged.posterURL = detail.posterURL ?? work.posterURL
            merged.summary = detail.summary?.isEmpty == false ? detail.summary : work.summary
            merged.synopsis = detail.synopsis?.isEmpty == false ? detail.synopsis : work.synopsis
            work = merged; lines = manifest.lines.filter { !$0.key.isEmpty }; loading = false
            selectedLine = (lines.first(where: \.playable) ?? lines.first(where: \.available))?.key
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
    func loadEpisodes(reset: Bool) async {
        guard let line = selectedLine, lines.contains(where: { $0.key == line && $0.available }) else { return }
        if reset { episodeGeneration = UUID(); episodes = []; total = 0; page = 0 }
        else if loadingEpisodes || (page > 0 && episodes.count >= total) { return }
        let token = episodeGeneration, requestedPage = page + 1
        loadingEpisodes = true; episodeError = nil
        do {
            let response = try await service.episodes(work, line: line, page: requestedPage)
            try Task.checkCancellation()
            guard selectedLine == line, episodeGeneration == token else { return }
            var keys = Set(episodes.map(\.key))
            episodes += response.items.filter { keys.insert($0.key).inserted }
            total = max(response.total, episodes.count); page = requestedPage; loadingEpisodes = false
        } catch {
            guard selectedLine == line, episodeGeneration == token, !Task.isCancelled else { return }
            episodeError = error.localizedDescription; loadingEpisodes = false
        }
    }
    func checkLine() async {
        guard let line = selectedLine, checkingLine == nil else { return }
        let candidates = episodes.filter { $0.unsupportedReason == nil }
        guard let episode = candidates.first(where: { $0.number == 1 }) ?? candidates.first ?? episodes.first else { return }
        guard let selected = selection(episode) else {
            lineChecks[line] = AccessObservation(state: .unsupported, detail: episode.unsupportedReason ?? "该线路暂不支持", checkedAt: Date()); return
        }
        checkingLine = line
        defer { checkingLine = nil }
        do { _ = try await service.playback(selected); try Task.checkCancellation(); lineChecks[line] = AccessObservation(state: .resolved, detail: "首集地址可解析，未验证整片播放", checkedAt: Date()) }
        catch {
            if Task.isCancelled { return }
            let state: VerificationState
            if let error = error as? CatalogError, case .unsupportedMedia = error { state = .unsupported } else { state = .failed }
            lineChecks[line] = AccessObservation(state: state, detail: error.localizedDescription, checkedAt: Date())
        }
    }
    func lineStatus(_ line: VideoLine) -> String { line.entitlementRequired == true ? "需权限" : line.unsupportedReason != nil ? "暂不支持" : lineChecks[line.key]?.state.label ?? "未验证" }
    func selection(_ episode: VideoEpisode) -> MediaSelection? {
        guard episode.unsupportedReason == nil, let line = selectedLine, lines.first(where: { $0.key == line })?.playable == true, episodes.contains(episode) else { return nil }
        return MediaSelection(work: work, episode: episode, lineKey: line)
    }
}
