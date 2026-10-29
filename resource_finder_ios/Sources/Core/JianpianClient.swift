import Foundation
import Security

private struct JPEnvelope: Decodable {
    let v: Int
    let alg: String
    let nonce: String
    let data: String
}
struct GuestIdentity: Codable {
    let installationID: String
    let credential: String
    static func load() throws -> GuestIdentity {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.resourcefinder.ios.guest",
                                   kSecAttrAccount as String: "installation"]
        var item: CFTypeRef?
        var read = query
        read[kSecReturnData as String] = true
        let result = SecItemCopyMatching(read as CFDictionary, &item)
        if result == errSecSuccess {
            guard let data = item as? Data else { throw CatalogError.secureStorage }
            return try JSONDecoder().decode(GuestIdentity.self, from: data)
        }
        guard result == errSecItemNotFound else { throw CatalogError.keychain(result) }
        let identity = GuestIdentity(installationID: UUID().uuidString.lowercased(), credential: JianpianCrypto.encode(try JianpianCrypto.random(32)))
        var insert = query
        insert[kSecValueData as String] = try JSONEncoder().encode(identity)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CatalogError.keychain(addStatus) }
        return identity
    }
}
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
@MainActor final class JianpianClient {
    private let identity: GuestIdentity
    private let crypto: JianpianCrypto
    private let session: URLSession
    init(identity: GuestIdentity) {
        self.identity = identity
        crypto = JianpianCrypto(installationID: identity.installationID, credential: identity.credential)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    static func encodedURI(path: String, query: [(String, String)]) throws -> String {
        guard path.range(of: #"^(search|works/[1-9][0-9]*(/(episodes|playback-manifest|media-lines))?|media/access)$"#, options: .regularExpression) != nil else { throw CatalogError.invalidRequest }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = try query.map { key, value -> String in
            guard let k = key.addingPercentEncoding(withAllowedCharacters: allowed), let v = value.addingPercentEncoding(withAllowedCharacters: allowed) else { throw CatalogError.invalidRequest }
            return "\(k)=\(v)"
        }
        return "/api/v1/\(path)" + (pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&"))
    }
    func request<T: Decodable>(_ path: String, query: [(String, String)] = [], body: Data? = nil) async throws -> T {
        var parameters = query
        if body == nil { parameters.append(("__jp_crypto_request", try JianpianCrypto.random(12).map { String(format: "%02x", $0) }.joined())) }
        let uri = try Self.encodedURI(path: path, query: parameters)
        guard let url = URL(string: "https://h5.jianpian.tv" + uri) else { throw CatalogError.invalidRequest }
        let context = JPRequestContext(method: body == nil ? "GET" : "POST", uri: uri,
                                       timestamp: Int64(Date().timeIntervalSince1970), nonce: JianpianCrypto.encode(try JianpianCrypto.random(12)))
        var wire = Data()
        if let body {
            wire = try JSONSerialization.data(withJSONObject: ["v": 1, "alg": "A256GCM", "ts": context.timestamp, "data": crypto.encryptRequest(context, plaintext: body)], options: [.sortedKeys])
        }
        var request = URLRequest(url: url)
        request.httpMethod = context.method
        if body != nil { request.httpBody = wire; request.setValue("application/vnd.jp.encrypted+json", forHTTPHeaderField: "Content-Type") }
        let headers = ["User-Agent": "ResourceFinder/0.1 iOS", "Accept": "application/json, application/problem+json",
                       "Accept-Language": "zh-CN", "X-Client-App": "jp", "X-Client-Platform": "h5",
                       "X-Client-Version": "5.0.76", "X-Client-Build": "1", "X-Device-ID": identity.installationID,
                       "X-JP-Runtime-Authorization": "Bearer \(identity.credential)", "X-JP-Crypto-Version": "1",
                       "X-JP-Timestamp": String(context.timestamp), "X-JP-Nonce": context.nonce,
                       "X-JP-Signature": crypto.signature(context, body: wire)]
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 2_000_000 else { throw CatalogError.invalidResponse }
        var payload = data
        if http.value(forHTTPHeaderField: "X-JP-Crypto-Version") == "1" || (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("application/vnd.jp.encrypted+json") {
            do {
                let envelope = try JSONDecoder().decode(JPEnvelope.self, from: data)
                guard envelope.v == 1, envelope.alg == "A256GCM" else { throw CatalogError.invalidResponse }
                payload = try crypto.decryptResponse(context, status: http.statusCode, nonce: envelope.nonce, data: envelope.data)
            } catch { throw CatalogError.invalidResponse }
        }
        guard (200..<300).contains(http.statusCode) else { throw CatalogError.http(http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: payload) }
        catch { throw CatalogError.invalidResponse }
    }
}
