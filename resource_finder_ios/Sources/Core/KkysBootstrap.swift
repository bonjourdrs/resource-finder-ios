import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

enum KkysBootstrap {
    static let seeds: [String] = ["https://www.kkys19.com/", "https://www.kkys20.com/"]
    private static let domains: [String] = ["pv.dsmovie2019.tv", "pv.ddushe.com", "pv.kekedh.com"]
    // Public catalog bootstrap configuration, independent of the user's identity.
    private static let key = Data("f0c9bb729c939a350b5e56049fd562fc".utf8)
    private static let iv = Data("d96b212338ec775c".utf8)
    static func discover() async -> [String] {
        for domain in domains {
            do {
                var components = URLComponents(string: "https://doh.pub/dns-query")!
                components.queryItems = [URLQueryItem(name: "name", value: domain), URLQueryItem(name: "type", value: "TXT")]
                let page = try await ProviderHTTP.get(components.url!, limit: 65536, accept: "application/dns-json")
                guard let root = try JSONSerialization.jsonObject(with: Data(page.body.utf8)) as? [String: Any], let answers = root["Answer"] as? [[String: Any]] else { continue }
                var sites: [String] = []
                for answer in answers where answer["type"] as? Int == 16 {
                    guard let raw = answer["data"] as? String, let data = Data(base64Encoded: raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))), let plain = decrypt(data), plain.hasPrefix("$") else { continue }
                    for host in plain.dropFirst().components(separatedBy: ",") {
                        if !PublicCatalogParser.matches(#"^[A-Za-z0-9.-]+(?::[0-9]{1,5})?$"#, host).isEmpty, let url = URL(string: "https://" + host + "/"), PublicCatalogParser.publicHTTPS(url) { sites.append(url.absoluteString) }
                    }
                }
                if !sites.isEmpty { return Array(Set(sites)).sorted() }
            } catch { if Task.isCancelled { return [] } }
        }
        return []
    }
    private static func decrypt(_ data: Data) -> String? {
        #if canImport(CommonCrypto)
        var output = Data(count: data.count + kCCBlockSizeAES128), written = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in key.withUnsafeBytes { k in iv.withUnsafeBytes { initial in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, initial.baseAddress, input.baseAddress, data.count, out.baseAddress, outputCapacity, &written)
        } } } }
        guard status == kCCSuccess else { return nil }
        return String(data: output.prefix(written), encoding: .utf8)
        #else
        return nil
        #endif
    }
}
