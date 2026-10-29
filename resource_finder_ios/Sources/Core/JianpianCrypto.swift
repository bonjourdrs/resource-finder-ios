import Foundation
import CryptoKit
import Security

struct JPRequestContext {
    let method: String
    let uri: String
    let timestamp: Int64
    let nonce: String
}
struct JianpianCrypto {
    let installationID: String
    private let root: Data
    init(installationID: String, credential: String) {
        self.installationID = installationID
        root = Self.mac(Data(SHA256.hash(data: Data("jp-api-v1\0\(installationID)".utf8))), Data(credential.utf8))
    }
    private func key(_ label: String) -> Data { Self.mac(root, Data("\(label)\u{01}".utf8)) }
    func signature(_ context: JPRequestContext, body: Data) -> String {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let message = "\(context.method)\n\(context.uri)\n\(context.timestamp)\n\(context.nonce)\n\(hash)"
        return Self.encode(Self.mac(key("jp-api-request-auth-v1"), Data(message.utf8)))
    }
    func encryptRequest(_ context: JPRequestContext, plaintext: Data) throws -> String {
        let nonce = try AES.GCM.Nonce(data: Self.decode(context.nonce))
        let aad = "jp-api-request-v1\n\(context.method)\n\(context.uri)\n\(context.timestamp)\n\(context.nonce)\n\(installationID)"
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key("jp-api-request-body-v1")), nonce: nonce, authenticating: Data(aad.utf8))
        return Self.encode(sealed.ciphertext + sealed.tag)
    }
    func decryptResponse(_ context: JPRequestContext, status: Int, nonce: String, data: String) throws -> Data {
        let bytes = try Self.decode(data), iv = try Self.decode(nonce)
        guard bytes.count >= 16, iv.count == 12 else { throw CatalogError.invalidResponse }
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: bytes.dropLast(16), tag: bytes.suffix(16))
        let aad = "jp-api-response-v1\n\(context.method)\n\(context.uri)\n\(status)\n\(context.timestamp)\n\(context.nonce)\n\(installationID)"
        return try AES.GCM.open(sealed, using: SymmetricKey(data: key("jp-api-response-body-v1")), authenticating: Data(aad.utf8))
    }
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ string: String) throws -> Data {
        var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { throw CatalogError.invalidResponse }
        return data
    }
    static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { buffer in SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!) }
        guard result == errSecSuccess else { throw CatalogError.secureStorage }
        return data
    }
    private static func mac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}
