import Foundation

struct HLSCachedResource: Codable {
    let name: String
    let url: URL
    let key: Bool
    var complete = false
    var bytes: Int64 = 0
}
struct HLSCacheJob: Codable {
    let attempt: UUID
    let rootName: String
    let manifests: [String]
    let headers: [String: String]
    var resources: [HLSCachedResource]
    var finished: Bool { resources.allSatisfy(\.complete) }
    func save(_ folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent("job.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func read(_ folder: URL, attempt: UUID) throws -> HLSCacheJob {
        let job = try JSONDecoder().decode(Self.self, from: Data(contentsOf: folder.appendingPathComponent("job.json")))
        guard job.attempt == attempt, job.resources.count <= 20_000, job.manifests.count <= 32,
              job.manifests.allSatisfy({ safeName($0) }), job.resources.allSatisfy({ safeName($0.name) }), safeName(job.rootName) else { throw DownloadFailure.incomplete }
        return job
    }
    static func safeName(_ name: String) -> Bool { !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".." }
    func validate(_ folder: URL) throws {
        guard finished, manifests.contains(rootName), !resources.isEmpty else { throw DownloadFailure.incomplete }
        for name in manifests {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            guard data.count <= 2_097_152, String(data: data, encoding: .utf8)?.hasPrefix("#EXTM3U") == true else { throw DownloadFailure.incomplete }
        }
        for resource in resources {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(resource.name).path)
            guard let size = attributes[.size] as? NSNumber, resource.bytes > 0, size.int64Value == resource.bytes, !resource.key || resource.bytes == 16 else { throw DownloadFailure.incomplete }
        }
    }
}

/// Standard HLS cache: manifests, AES identity keys and media stay portable.
/// Each media object uses native background URLSession transfers. No private
/// movpkg parsing, local background proxy or transcoding is required for TVs.
@MainActor enum PortableHLS {
    static func prepare(source: PlaybackSource, keys: [String: Data], folder: URL, attempt: UUID, allowsCellular: Bool) async throws -> HLSCacheJob {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowsCellular
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var names: [URL: String] = [:], pending: [URL] = [], resources: [HLSCachedResource] = [], resourceNames: [URL: String] = [:]
        func manifest(_ url: URL) throws -> String {
            if let name = names[url] { return name }
            guard names.count < 32 else { throw DownloadFailure.unsupported }
            let name = names.isEmpty ? "index.m3u8" : "m\(names.count).m3u8"
            names[url] = name; pending.append(url); return name
        }
        func remote(_ text: String, base: URL) throws -> URL {
            guard !text.contains("{$"), let url = URL(string: text, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil, url.host != nil else { throw DownloadFailure.unsupported }
            return url
        }
        func resource(_ url: URL, key: Bool, initialization: Bool = false) throws -> String {
            if let name = resourceNames[url] { return name }
            guard resources.count < 20_000 else { throw DownloadFailure.unsupported }
            let ext: String
            if key { ext = "key" }
            else if ["ts", "m4s", "mp4", "aac", "vtt"].contains(url.pathExtension.lowercased()) { ext = url.pathExtension.lowercased() }
            else { ext = initialization ? "mp4" : "bin" }
            let name = "r\(resources.count).\(ext)"
            var item = HLSCachedResource(name: name, url: url, key: key)
            if key {
                guard let data = keys[url.absoluteString], data.count == 16 else { throw DownloadFailure.incomplete }
                try data.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                item.complete = true; item.bytes = 16
            }
            resources.append(item); resourceNames[url] = name; return name
        }
        let root = try manifest(source.url), expression = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        while let url = pending.popLast() {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            source.requestHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue(nil, forHTTPHeaderField: "Range")
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw DownloadFailure.incomplete }
            var data = Data()
            for try await byte in stream { data.append(byte); guard data.count <= 2_097_152 else { throw DownloadFailure.unsupported } }
            guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw DownloadFailure.unsupported }
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if lines.contains(where: { $0.hasPrefix("#EXTINF:") }) {
                guard lines.contains("#EXT-X-ENDLIST") else { throw DownloadFailure.unsupported }
            }
            guard !lines.contains(where: { $0.hasPrefix("#EXT-X-CONTENT-STEERING:") || ($0.hasPrefix("#EXT-X-DATERANGE:") && $0.contains("ASSET-URI")) || ($0.hasPrefix("#EXT-X-SESSION-DATA:") && $0.contains("URI=")) }) else { throw DownloadFailure.unsupported }
            let base = response.url ?? url
            var variant = false, output: [String] = []
            for line in lines {
                if line.hasPrefix("#") {
                    if line.hasPrefix("#EXT-X-STREAM-INF:") { variant = true }
                    var changed = line
                    for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                        guard let range = Range(match.range(at: 1), in: changed) else { throw DownloadFailure.unsupported }
                        let target = try remote(String(changed[range]), base: base)
                        let playlist = line.hasPrefix("#EXT-X-MEDIA:") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
                        let key = line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:")
                        let name = try playlist ? manifest(target) : resource(target, key: key, initialization: line.hasPrefix("#EXT-X-MAP:"))
                        changed.replaceSubrange(range, with: name)
                    }
                    output.append(changed)
                } else if !line.isEmpty {
                    let target = try remote(line, base: base)
                    output.append(try variant ? manifest(target) : resource(target, key: false)); variant = false
                } else { output.append(line) }
            }
            try Data(output.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent(names[url]!), options: .atomic)
        }
        let job = HLSCacheJob(attempt: attempt, rootName: root, manifests: Array(names.values), headers: source.requestHeaders, resources: resources)
        guard !resources.isEmpty else { throw DownloadFailure.unsupported }
        try job.save(folder); return job
    }
}
