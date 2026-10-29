import Foundation

/// Native HLS packages retain media segments but may still reference remote
/// identity AES keys. Collect those keys before declaring a download offline.
enum HLSKeys {
    static func read(_ url: URL) throws -> [String: Data] {
        let keys = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))
        guard keys.values.allSatisfy({ $0.count == 16 }), keys.keys.allSatisfy({ ["http", "https"].contains(URL(string: $0)?.scheme ?? "") }) else { throw DownloadFailure.incomplete }
        return keys
    }
    static func attributes(_ line: String) -> [String: String] {
        let pattern = #"([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let value = line.components(separatedBy: ":").dropFirst().joined(separator: ":") as NSString
        var result: [String: String] = [:]
        for match in expression.matches(in: value as String, range: NSRange(location: 0, length: value.length)) {
            let range = match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2)
            result[value.substring(with: match.range(at: 1))] = value.substring(with: range)
        }
        return result
    }
    static func collect(source: PlaybackSource, allowsCellular: Bool) async throws -> [String: Data] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowsCellular
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func fetch(_ url: URL, maximum: Int) async throws -> (Data, URL) {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw DownloadFailure.unsupported }
            let request = NSMutableURLRequest(url: url)
            StoredKeyURLProtocol.permitNetwork(request)
            if let agent = source.userAgent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
            let result: (Data, URLResponse)
            do { result = try await session.data(for: request as URLRequest) }
            catch {
                let value = error as NSError
                if value.domain == NSURLErrorDomain && value.code == NSURLErrorAppTransportSecurityRequiresSecureConnection { throw DownloadFailure.unsupported }
                throw error
            }
            let (data, response) = result
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw DownloadFailure.incomplete }
            guard data.count <= maximum else { throw DownloadFailure.unsupported }
            return (data, response.url ?? url)
        }
        var pending = [source.url], visited = Set<String>(), keys: [String: Data] = [:]
        while let url = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(url.absoluteString).inserted else { continue }
            guard visited.count <= 32 else { throw DownloadFailure.unsupported }
            let (data, base) = try await fetch(url, maximum: 1_048_576)
            guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw DownloadFailure.unsupported }
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var variant = false
            for line in lines where !line.isEmpty {
                if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                    let values = attributes(line)
                    if values["METHOD"] == "NONE" { continue }
                    guard values["METHOD"] == "AES-128", values["KEYFORMAT", default: "identity"] == "identity",
                          let reference = values["URI"], let keyURL = URL(string: reference, relativeTo: base)?.absoluteURL else { throw DownloadFailure.unsupported }
                    let id = keyURL.absoluteString
                    if keys[id] == nil {
                        guard keys.count < 128 else { throw DownloadFailure.unsupported }
                        let (bytes, _) = try await fetch(keyURL, maximum: 16)
                        guard bytes.count == 16 else { throw DownloadFailure.incomplete }
                        keys[id] = bytes
                    }
                } else if line.hasPrefix("#EXT-X-STREAM-INF:") { variant = true }
                else if line.hasPrefix("#EXT-X-MEDIA:") {
                    if let reference = attributes(line)["URI"], let child = URL(string: reference, relativeTo: base)?.absoluteURL { pending.append(child) }
                } else if !line.hasPrefix("#"), variant {
                    guard let child = URL(string: line, relativeTo: base)?.absoluteURL else { throw DownloadFailure.unsupported }
                    pending.append(child); variant = false
                }
            }
        }
        return keys
    }
}

/// Activates saved identity keys only for the lifetime of offline playback.
@MainActor final class OfflineContentKeys {
    private let handle: UUID
    var responseCount: Int { StoredKeyURLProtocol.responseCount(handle) }
    init(url: URL) throws { handle = StoredKeyURLProtocol.activate(try HLSKeys.read(url)) }
    deinit { StoredKeyURLProtocol.deactivate(handle) }
}
