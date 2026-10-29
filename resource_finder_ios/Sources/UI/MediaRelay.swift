import Foundation
import Network

/// Header-aware streaming relay. Routes are random capabilities registered by a
/// trusted descriptor or its HLS manifests; clients cannot choose an upstream URL.
@MainActor final class MediaRelay {
    private let source: PlaybackSource
    private let listener: NWListener
    private let queue = DispatchQueue(label: "resourcefinder.media.relay")
    private let session: URLSession
    private let token = UUID().uuidString
    private let address: String
    private let allowedPeer: String?
    private var routes: [String: URL] = [:]
    private var reverse: [URL: String] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var base: URL?
    private var stopped = false
    private(set) var keyResponses = 0
    init(source: PlaybackSource, address: String = "127.0.0.1", allowedPeer: String? = nil, allowsCellular: Bool = true) throws {
        self.source = source; self.address = address; self.allowedPeer = allowedPeer
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        listener = try NWListener(using: parameters)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.allowsCellularAccess = allowsCellular
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, !completed else { return }
                    switch state {
                    case .ready:
                        completed = true
                        self.base = URL(string: "http://\(self.address):\(self.listener.port!.rawValue)")!
                        continuation.resume()
                    case .failed(let error): completed = true; continuation.resume(throwing: error)
                    case .cancelled: completed = true; continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, !self.stopped, self.connections.count < 12 else { connection.cancel(); return }
                    if let allowedPeer = self.allowedPeer {
                        guard case .hostPort(let host, _) = connection.endpoint, String(describing: host) == allowedPeer else { connection.cancel(); return }
                    }
                    let id = UUID(); self.connections[id] = connection
                    connection.stateUpdateHandler = { [weak self] state in
                        if case .cancelled = state { Task { @MainActor in self?.jobs.removeValue(forKey: id)?.cancel(); self?.connections.removeValue(forKey: id) } }
                    }
                    connection.start(queue: self.queue); self.receive(id, connection, bytes: Data())
                }
            }
            listener.start(queue: queue)
        }
        return try route(source.url, playlist: source.kind == .hls)
    }
    private func route(_ url: URL, playlist: Bool = false) throws -> URL {
        guard let base, routes.count < 20_000, url.user == nil, url.password == nil,
              url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw CatalogError.unsupportedMedia }
        if url.isFileURL {
            if let root = source.offlineRoot {
                let path = root.standardizedFileURL.path, prefix = path.hasSuffix("/") ? path : path + "/"
                guard url.standardizedFileURL.path.hasPrefix(prefix), ["m3u8", "ts", "m4s", "mp4", "aac", "vtt", "key", "bin"].contains(url.pathExtension) else { throw DownloadFailure.incomplete }
            } else { guard url == source.url else { throw DownloadFailure.incomplete } }
        }
        if let key = reverse[url] { return base.appendingPathComponent(key) }
        let ext = playlist || url.pathExtension.lowercased() == "m3u8" ? "m3u8" : url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let key = "\(token)/\(routes.count).\(ext)"; routes[key] = url; reverse[url] = key
        return base.appendingPathComponent(key)
    }
    private func receive(_ id: UUID, _ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] part, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var data = bytes; if let part { data.append(part) }
                guard error == nil, data.count <= 32_768, !self.stopped else { connection.cancel(); return }
                if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                    let text = String(decoding: data[..<end.upperBound], as: UTF8.self)
                    self.jobs[id] = Task { [weak self] in
                        defer { connection.cancel(); self?.jobs.removeValue(forKey: id); self?.connections.removeValue(forKey: id) }
                        do { try await self?.respond(connection, request: text) }
                        catch { try? await self?.send(connection, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) }
                    }
                } else if !done { self.receive(id, connection, bytes: data) } else { connection.cancel() }
            }
        }
    }
    private func send(_ connection: NWConnection, _ bytes: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in if let error { c.resume(throwing: error) } else { c.resume() } })
        }
    }
    private func respond(_ connection: NWConnection, request text: String) async throws {
        let lines = text.components(separatedBy: "\r\n"), words = (lines.first ?? "").split(separator: " ")
        guard words.count == 3, ["GET", "HEAD"].contains(String(words[0])), let url = routes[String(words[1]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))] else {
            try await send(connection, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
        }
        let head = words[0] == "HEAD"
        let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if url.isFileURL { try await file(connection, url: url, range: range, head: head); return }
        var request = URLRequest(url: url); request.httpMethod = head ? "HEAD" : "GET"
        source.requestHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CatalogError.invalidResponse }
        let playlist = !head && (String(words[1]).hasSuffix(".m3u8") || (response.mimeType ?? "").lowercased().contains("mpegurl"))
        if playlist && (200..<300).contains(response.statusCode) {
            var data = Data()
            for try await byte in stream { data.append(byte); if data.count > 2_097_152 { throw CatalogError.unsupportedMedia } }
            guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw CatalogError.invalidResponse }
            let rewritten = try rewrite(text, base: response.url ?? url)
            let body = Data(rewritten.utf8)
            try await send(connection, Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)); try await send(connection, body)
        } else {
            var headers = "HTTP/1.1 \(response.statusCode) Response\r\nConnection: close\r\n"
            for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
                if let value = response.value(forHTTPHeaderField: name), !value.contains("\r"), !value.contains("\n") { headers += "\(name): \(value)\r\n" }
            }
            try await send(connection, Data((headers + "\r\n").utf8))
            if !head {
                var chunk = Data(); chunk.reserveCapacity(32_768)
                for try await byte in stream {
                    chunk.append(byte)
                    if chunk.count >= 32_768 { try await send(connection, chunk); chunk.removeAll(keepingCapacity: true) }
                }
                if !chunk.isEmpty { try await send(connection, chunk) }
            }
        }
    }
    func rewrite(_ text: String, base origin: URL) throws -> String {
        let expression = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        return try text.components(separatedBy: .newlines).map { line in
            if line.hasPrefix("#") {
                var output = line
                let matches = expression.matches(in: line, range: NSRange(line.startIndex..., in: line))
                for match in matches.reversed() {
                    guard let range = Range(match.range(at: 1), in: output), let remote = URL(string: String(output[range]), relativeTo: origin)?.absoluteURL else { throw CatalogError.invalidResponse }
                    output.replaceSubrange(range, with: try route(remote).absoluteString)
                }
                return output
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            guard let remote = URL(string: line.trimmingCharacters(in: .whitespaces), relativeTo: origin)?.absoluteURL else { throw CatalogError.invalidResponse }
            return try route(remote).absoluteString
        }.joined(separator: "\n")
    }
    private func file(_ connection: NWConnection, url: URL, range: String?, head: Bool) async throws {
        if url.pathExtension == "m3u8" {
            let data = try Data(contentsOf: url)
            guard data.count <= 2_097_152, let text = String(data: data, encoding: .utf8) else { throw DownloadFailure.incomplete }
            let body = Data(try rewrite(text, base: url).utf8)
            try await send(connection, Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8))
            if !head { try await send(connection, body) }; return
        }
        if url.pathExtension == "key" { keyResponses += 1 }
        let type = url.pathExtension == "ts" ? "video/mp2t" : url.pathExtension == "mp4" ? "video/mp4" : url.pathExtension == "vtt" ? "text/vtt" : "application/octet-stream"
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var lower: Int64 = 0, upper = size - 1
        if let range {
            let values = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-", omittingEmptySubsequences: false)
            guard range.hasPrefix("bytes="), !range.contains(","), values.count == 2 else { throw CatalogError.invalidRequest }
            if values[0].isEmpty, let suffix = Int64(values[1]), suffix > 0 { lower = max(0, size - suffix) }
            else { guard let start = Int64(values[0]) else { throw CatalogError.invalidRequest }; lower = start; if let end = Int64(values[1]) { upper = min(upper, end) } }
        }
        guard lower >= 0, lower <= upper, upper < size else {
            try await send(connection, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
        }
        let extra = range == nil ? "" : "Content-Range: bytes \(lower)-\(upper)/\(size)\r\n"
        try await send(connection, Data("HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: \(type)\r\nAccept-Ranges: bytes\r\nContent-Length: \(upper - lower + 1)\r\n\(extra)Connection: close\r\n\r\n".utf8))
        guard !head else { return }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }; try file.seek(toOffset: UInt64(lower))
        var remaining = upper - lower + 1
        while remaining > 0 {
            let bytes = try file.read(upToCount: Int(min(remaining, 65_536))) ?? Data()
            guard !bytes.isEmpty else { throw DownloadFailure.incomplete }; remaining -= Int64(bytes.count)
            try await send(connection, bytes)
        }
    }
    func stop() { stopped = true; listener.cancel(); jobs.values.forEach { $0.cancel() }; jobs.removeAll(); connections.values.forEach { $0.cancel() }; connections.removeAll(); session.invalidateAndCancel() }
}
