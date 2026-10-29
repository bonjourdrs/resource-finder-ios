import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftSoup

struct ProviderPage: Sendable { let body: String; let url: URL }
private final class BoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProviderPage, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var bytes = Data()
    private var finalURL: URL?
    private var cancelled = false
    private var redirects = 0
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func load(_ url: URL, accept: String) async throws -> ProviderPage {
        guard PublicCatalogParser.publicHTTPS(url) else { throw CatalogError.invalidRequest }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 28
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("ResourceFinder/0.3 iOS", forHTTPHeaderField: "User-Agent")
                request.setValue(accept, forHTTPHeaderField: "Accept")
                task = session.dataTask(with: request)
                let pending = task; lock.unlock(); pending?.resume()
            }
        }, onCancel: { self.cancel() })
    }
    private func cancel() { lock.lock(); cancelled = true; let pending = task; lock.unlock(); pending?.cancel(); finish(.failure(CancellationError())) }
    private func finish(_ result: Result<ProviderPage, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; let session = self.session; self.session = nil; task = nil; lock.unlock()
        pending?.resume(with: result); session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard redirects < 4, let url = request.url, PublicCatalogParser.publicHTTPS(url) else { completionHandler(nil); finish(.failure(CatalogError.invalidResponse)); return }
        redirects += 1; completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = response.url, PublicCatalogParser.publicHTTPS(url) else { completionHandler(.cancel); finish(.failure(CatalogError.invalidResponse)); return }
        guard (200...299).contains(http.statusCode) else { completionHandler(.cancel); finish(.failure(CatalogError.http(http.statusCode))); return }
        guard response.expectedContentLength <= Int64(limit) else { completionHandler(.cancel); finish(.failure(CatalogError.message("资源响应过大，请换来源"))); return }
        finalURL = url; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= limit else { dataTask.cancel(); finish(.failure(CatalogError.message("资源响应过大，请换来源"))); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let url = finalURL, let body = String(data: bytes, encoding: .utf8) else { finish(.failure(CatalogError.invalidResponse)); return }
        finish(.success(ProviderPage(body: body.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")), url: url)))
    }
}
enum ProviderHTTP {
    static func get(_ url: URL, limit: Int = 4 * 1024 * 1024, accept: String = "text/html,application/json,application/vnd.apple.mpegurl,*/*;q=0.8") async throws -> ProviderPage {
        try await BoundedTransfer(limit: limit).load(url, accept: accept)
    }
}
struct HLSInspection: Sendable { let variants: [URL]; let segments: Int; let seconds: Double; let ended: Bool }
enum ProviderHLS {
    static func inspect(_ value: String, base: URL) throws -> HLSInspection {
        let body = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("#EXTM3U") else { throw CatalogError.message("媒体不是有效 HLS 清单，请换线路") }
        let rows = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for key in rows where key.hasPrefix("#EXT-X-KEY:") {
            let attributes = PublicCatalogParser.matches(#"([A-Z0-9-]+)=("[^"]*"|[^,]+)"#, key)
            let fields = Dictionary(attributes.map { ($0[1], $0[2].trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }, uniquingKeysWith: { _, last in last })
            guard ["NONE", "AES-128"].contains(fields["METHOD"] ?? ""), (fields["KEYFORMAT"] ?? "identity") == "identity" else { throw CatalogError.unsupportedMedia }
        }
        var variants: [URL] = [], durations: [Double] = []
        for (i, row) in rows.enumerated() {
            if row.hasPrefix("#EXT-X-STREAM-INF:"), let next = rows.dropFirst(i + 1).first(where: { !$0.hasPrefix("#") }), let url = URL(string: next, relativeTo: base)?.absoluteURL { variants.append(url) }
            if row.hasPrefix("#EXTINF:") {
                guard let n = Double(row.dropFirst(8).split(separator: ",").first ?? ""), n.isFinite, n > 0 else { throw CatalogError.invalidResponse }
                durations.append(n)
            }
        }
        let ended = rows.contains("#EXT-X-ENDLIST")
        guard !variants.isEmpty || !durations.isEmpty else { throw CatalogError.invalidResponse }
        if variants.isEmpty && ended && durations.count <= 3 && durations.reduce(0, +) < 15 { throw CatalogError.message("该线路返回过短提示片，请换线路") }
        return HLSInspection(variants: variants, segments: durations.count, seconds: durations.reduce(0, +), ended: ended)
    }
    static func validate(_ url: URL) async throws {
        var next = url
        for _ in 0..<4 {
            let page = try await ProviderHTTP.get(next, limit: 2 * 1024 * 1024)
            let info = try inspect(page.body, base: page.url)
            if let variant = info.variants.first { next = variant } else { return }
        }
        throw CatalogError.message("播放清单嵌套过深，请换线路")
    }
}

@MainActor final class PublicCatalogProvider {
    let config: ProviderConfig
    private var cached: [Int64: (Date, ProviderWork)] = [:]
    private var home: (Date, ProviderPage)?
    private var nextPages: [String: [Int: URL]] = [:]
    private var lastAPI: TimeInterval = 0
    init(config: ProviderConfig) { self.config = config }
    func invalidate(_ id: Int64) { cached.removeValue(forKey: id) }
    private func endpoint(_ params: [String: String]) async throws -> ProviderPage {
        let now = ProcessInfo.processInfo.systemUptime
        let scheduled = max(now, lastAPI + config.interval)
        lastAPI = scheduled
        if scheduled > now { try await Task.sleep(nanoseconds: UInt64((scheduled - now) * 1_000_000_000)) }
        guard let api = config.api, var components = URLComponents(string: api) else { throw CatalogError.invalidRequest }
        components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw CatalogError.invalidRequest }
        return try await ProviderHTTP.get(url)
    }
    private func homepage() async throws -> ProviderPage {
        if let home, Date().timeIntervalSince(home.0) < 600 { return home.1 }
        var candidates = KkysBootstrap.seeds
        for round in 0...1 {
            for entry in candidates {
                do {
                    guard let url = URL(string: entry) else { continue }
                    let page = try await ProviderHTTP.get(url)
                    guard try SwiftSoup.parse(page.body).select("form[action='/search'] input[name=t]").first() != nil else { continue }
                    home = (Date(), page); return page
                } catch { if Task.isCancelled { throw CancellationError() } }
            }
            if round == 0 { candidates = await KkysBootstrap.discover() }
        }
        throw CatalogError.message("可可入口暂不可用，可重试或换来源")
    }
    private func kkysPage(_ path: String) async throws -> ProviderPage {
        let root = try await homepage()
        guard let url = URL(string: path, relativeTo: root.url)?.absoluteURL else { throw CatalogError.invalidRequest }
        do { return try await ProviderHTTP.get(url) } catch { home = nil; throw error }
    }
    func search(_ query: String, page: Int) async throws -> ProviderSearch {
        guard page > 0, !query.isEmpty else { throw CatalogError.invalidRequest }
        if config.id != "kkys" {
            let result = try await endpoint(["ac": "detail", "wd": query, "pg": String(page)])
            return try PublicCatalogParser.searchJSON(result.body, config: config, page: page)
        }
        let root = try await homepage()
        let url: URL
        if page == 1 {
            let doc = try SwiftSoup.parse(root.body)
            guard let input = try doc.select("form[action='/search'] input[name=t]").first(), var components = URLComponents(url: root.url, resolvingAgainstBaseURL: true) else { throw CatalogError.invalidResponse }
            components.path = "/search"; components.queryItems = [URLQueryItem(name: "t", value: try input.attr("value")), URLQueryItem(name: "k", value: query)]
            guard let target = components.url else { throw CatalogError.invalidRequest }; url = target
        } else {
            guard let target = nextPages[query]?[page] else { return ProviderSearch(works: [], more: false) }; url = target
        }
        let result = try await ProviderHTTP.get(url)
        let parsed = try PublicCatalogParser.searchKKYS(result.body, base: result.url)
        try Task.checkCancellation()
        if page == 1 { nextPages[query] = [:] }
        if let next = parsed.nextURL { nextPages[query, default: [:]][page + 1] = next }
        if nextPages.count > 20, let old = nextPages.keys.first(where: { $0 != query }) { nextPages.removeValue(forKey: old) }
        return parsed
    }
    func work(_ id: Int64, fresh: Bool = false) async throws -> ProviderWork {
        if !fresh, let item = cached[id], Date().timeIntervalSince(item.0) < 120 { return item.1 }
        let result: ProviderWork
        if config.id == "kkys" {
            let page = try await kkysPage("/detail/\(id).html")
            result = try PublicCatalogParser.detailKKYS(page.body, base: page.url, id: id)
        } else {
            let page = try await endpoint(["ac": "detail", "ids": String(id)])
            result = try PublicCatalogParser.detailJSON(page.body, config: config, id: id)
        }
        try Task.checkCancellation(); cached[id] = (Date(), result)
        if cached.count > 30, let old = cached.keys.first(where: { $0 != id }) { cached.removeValue(forKey: old) }
        return result
    }
    func resolve(_ selection: MediaSelection) async throws -> PlaybackSource {
        guard selection.work.providerID == config.id else { throw CatalogError.mismatchedMedia }
        let work = try await work(selection.work.id, fresh: true)
        guard let line = work.lines.first(where: { $0.line.key == selection.lineKey }), let item = line.episodes.first(where: { $0.episode.key == selection.episode.key && $0.episode.name == selection.episode.name }) else { throw CatalogError.mismatchedMedia }
        let source: PlaybackSource
        if config.id == "kkys" {
            guard let url = item.url else { throw CatalogError.invalidResponse }
            let page = try await kkysPage(url.path)
            source = try PublicCatalogParser.mediaKKYS(page.body, base: page.url)
        } else {
            guard item.episode.unsupportedReason == nil, let url = item.url, let kind = item.kind else { throw CatalogError.unsupportedMedia }
            source = PlaybackSource(url: url, kind: kind)
        }
        if source.kind == .hls { try await ProviderHLS.validate(source.url) }
        return source
    }
}
