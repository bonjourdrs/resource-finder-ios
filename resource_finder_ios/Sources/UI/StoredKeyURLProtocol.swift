import Foundation

/// A scoped, memory-only response for identity HLS key URLs already downloaded
/// by this app. All other requests retain their normal URL loading behavior.
final class StoredKeyURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var records: [UUID: [String: Data]] = [:]
    private static var served: [UUID: Int] = [:]
    private static let bypassKey = "ResourceFinder.IgnoreStoredKey"
    static func permitNetwork(_ request: NSMutableURLRequest) { URLProtocol.setProperty(true, forKey: bypassKey, in: request) }
    static func install() { _ = URLProtocol.registerClass(StoredKeyURLProtocol.self) }
    static func activate(_ keys: [String: Data]) -> UUID {
        let id = UUID()
        lock.lock(); records[id] = keys; served[id] = 0; lock.unlock()
        return id
    }
    static func deactivate(_ id: UUID) { lock.lock(); records.removeValue(forKey: id); served.removeValue(forKey: id); lock.unlock() }
    static func responseCount(_ id: UUID) -> Int { lock.lock(); defer { lock.unlock() }; return served[id, default: 0] }
    private static func value(_ request: URLRequest, count: Bool) -> Data? {
        guard URLProtocol.property(forKey: bypassKey, in: request) as? Bool != true else { return nil }
        guard let url = request.url, ["http", "https"].contains(url.scheme ?? ""), ["GET", "HEAD"].contains(request.httpMethod ?? "GET") else { return nil }
        lock.lock(); defer { lock.unlock() }
        for (id, keys) in records {
            if let bytes = keys[url.absoluteString] {
                if count { served[id, default: 0] += 1 }
                return bytes
            }
        }
        return nil
    }
    override class func canInit(with request: URLRequest) -> Bool { value(request, count: false) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let bytes = Self.value(request, count: true), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream", "Content-Length": String(bytes.count), "Cache-Control": "no-store"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: bytes) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
