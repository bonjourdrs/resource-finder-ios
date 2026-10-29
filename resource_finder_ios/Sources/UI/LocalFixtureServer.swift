#if DEBUG
import Foundation
import Network

/// Serves only generated, bundled test assets on loopback. Not a production proxy.
final class LocalFixtureServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "resourcefinder.fixture.http")
    private let files: [String: Data]
    private let chunkDelay: Double
    private var connections: [NWConnection] = []
    private let lock = NSLock()
    private var count = 0
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    private(set) var baseURL: URL!
    init(files: [String: Data], chunkDelay: Double = 0) throws {
        self.files = files; self.chunkDelay = chunkDelay
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    baseURL = URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
                    continuation.resume()
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }; connections.append(connection)
                connection.start(queue: queue); receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] part, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = data; if let part { bytes.append(part) }
            guard bytes.count < 65_536, error == nil else { connection.cancel(); return }
            if let range = bytes.range(of: Data("\r\n\r\n".utf8)) { respond(connection, text: String(decoding: bytes[..<range.upperBound], as: UTF8.self)) }
            else if !complete { receive(connection, data: bytes) }
            else { connection.cancel() }
        }
    }
    private func respond(_ connection: NWConnection, text: String) {
        lock.lock(); count += 1; lock.unlock()
        let lines = text.components(separatedBy: "\r\n"), parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, ["GET", "HEAD"].contains(String(parts[0])), let file = files[String(parts[1]).components(separatedBy: "?")[0]] else {
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() }); return
        }
        var lower = 0, upper = max(0, file.count - 1), ranged = false
        if let line = lines.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
            let values = line.components(separatedBy: "=").last!.split(separator: "-", omittingEmptySubsequences: false)
            if values.count == 2 {
                if values[0].isEmpty, let suffix = Int(values[1]) { lower = max(0, file.count - suffix) }
                else { lower = Int(values[0]) ?? 0; upper = min(upper, Int(values[1]) ?? upper) }
                ranged = true
            }
        }
        guard lower >= 0, upper >= lower, upper < file.count else { connection.cancel(); return }
        let name = String(parts[1]), type = name.contains("m3u8") ? "application/vnd.apple.mpegurl" : name.contains(".ts") ? "video/mp2t" : name.contains(".key") ? "application/octet-stream" : "video/mp4"
        let rangeHeader = ranged ? "Content-Range: bytes \(lower)-\(upper)/\(file.count)\r\n" : ""
        let header = "HTTP/1.1 \(ranged ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(type)\r\nContent-Length: \(upper - lower + 1)\r\nAccept-Ranges: bytes\r\n\(rangeHeader)Connection: close\r\n\r\n"
        let body = parts[0] == "HEAD" ? Data() : file.subdata(in: lower..<(upper + 1))
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }; send(connection, data: body, offset: 0)
        })
    }
    private func send(_ connection: NWConnection, data: Data, offset: Int) {
        guard offset < data.count else { connection.cancel(); return }
        let end = min(data.count, offset + 8192)
        connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            queue.asyncAfter(deadline: .now() + chunkDelay) { [weak self] in self?.send(connection, data: data, offset: end) }
        })
    }
    func stop() { listener.cancel(); queue.async { [weak self] in self?.connections.forEach { $0.cancel() }; self?.connections = [] } }
    static func bundledFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in ["hls_index.m3u8", "hls_media.m3u8", "hls_part0.ts", "hls_part1.ts", "hls_part2.ts", "aes_index.m3u8", "aes_media.m3u8", "aes_part0.ts", "aes_part1.ts", "aes_part2.ts", "test.key"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "b64"), let bytes = Data(base64Encoded: try Data(contentsOf: url), options: .ignoreUnknownCharacters) else { throw CatalogError.invalidResponse }
            files["/" + name] = bytes
        }
        guard let url = Bundle.main.url(forResource: "playback.mp4", withExtension: "b64"), let data = Data(base64Encoded: try Data(contentsOf: url), options: .ignoreUnknownCharacters) else { throw CatalogError.invalidResponse }
        files["/video.mp4"] = data
        return files
    }
}
#endif
