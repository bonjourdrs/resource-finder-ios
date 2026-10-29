import Foundation

struct VideoWork: Codable, Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    var year: Int?
    var kind: String?
    var synopsis: String?
    var summary: String?
    var posterURL: String?
    var remarks: String?
    var sourceID: String? = nil
    var providerID: String { sourceID ?? "jianpian" }
    var sourceKey: String { "\(providerID == "jianpian" ? "jp" : providerID):\(id)" }
    var sourceName: String { ProviderRegistry.name(providerID) }
    var displaySummary: String { summary ?? synopsis ?? "暂无简介" }
    enum CodingKeys: String, CodingKey {
        case id, title, year, kind, synopsis, summary, remarks, sourceID
        case posterURL = "poster_url"
    }
}
struct SearchResponse: Decodable { let items: [VideoWork] }
struct VideoLine: Decodable, Identifiable, Sendable {
    let key: String
    let name: String
    let episodeCount: Int?
    let entitlementRequired: Bool?
    var unsupportedReason: String? = nil
    var id: String { key }
    var available: Bool { entitlementRequired != true }
    var playable: Bool { available && unsupportedReason == nil }
    enum CodingKeys: String, CodingKey {
        case key, name, unsupportedReason
        case episodeCount = "episode_count", entitlementRequired = "entitlement_required"
    }
}
struct PlaybackManifest: Decodable {
    let workID: Int64
    let lines: [VideoLine]
    enum CodingKeys: String, CodingKey { case workID = "work_id", lines }
}
struct VideoEpisode: Codable, Identifiable, Hashable, Sendable {
    let key: String
    let index: Int
    let name: String
    var number: Int? = nil
    var unsupportedReason: String? = nil
    var id: String { key }
}
struct EpisodeResponse: Decodable { let items: [VideoEpisode]; let total: Int }
struct MediaSelection: Codable, Identifiable, Hashable, Sendable {
    let work: VideoWork
    let episode: VideoEpisode
    let lineKey: String
    var id: String { "\(work.sourceKey):\(lineKey):\(episode.key)" }
}
struct PlaybackSource {
    let url: URL
    var userAgent: String?
    var kind: MediaKind = .progressive
    var offline: Bool = false
    var offlineKeys: URL?
}
enum MediaKind: String, Codable, Sendable { case hls, progressive }
struct MediaDescriptor: Decodable {
    struct Line: Decodable { let key: String }
    let url: String
    let protocolName: String
    let headers: [String: String]?
    let episodeKey: String
    let line: Line
    let fallback: Bool?
    enum CodingKeys: String, CodingKey {
        case url, headers, line, fallback
        case protocolName = "protocol", episodeKey = "episode_key"
    }
    func validated(for selection: MediaSelection) throws -> URL {
        guard fallback != true, episodeKey == selection.episode.key, line.key == selection.lineKey else {
            throw CatalogError.mismatchedMedia
        }
        guard let value = URL(string: url), ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              value.host != nil, value.user == nil, value.password == nil,
              ["hls", "mp4", "http", "https", "progressive"].contains(protocolName) else {
            throw CatalogError.unsupportedMedia
        }
        return value
    }
    // AVFoundation publicly supports a per-asset user agent. Other required
    // headers need an independently validated adapter; never silently omit them.
    func userAgent() throws -> String? {
        var agent: String?
        for (key, value) in headers ?? [:] {
            let lower = key.lowercased()
            if lower.hasPrefix("x-jp-") || lower == "x-device-id" || lower == "host" { continue }
            guard lower == "user-agent" else { throw CatalogError.unsupportedHeaders }
            agent = value
        }
        return agent
    }
}
enum CatalogError: LocalizedError {
    case invalidRequest, invalidResponse, mismatchedMedia, unsupportedMedia, unsupportedHeaders
    case http(Int), secureStorage, keychain(Int32), message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .invalidRequest: return "请求参数无效"
        case .invalidResponse: return "接口响应校验失败，请稍后重试"
        case .mismatchedMedia: return "返回的线路或剧集不一致，请重新选择"
        case .unsupportedMedia: return "该线路使用的格式暂不支持，请换一条线路"
        case .unsupportedHeaders: return "该线路需要额外媒体请求头，iOS 基础版暂不支持，请换线路"
        case .secureStorage, .keychain(_): return "无法安全保存本机访客身份，请重新启动应用"
        case .http(401): return "接口验证失败，请检查设备日期和时间"
        case .http(403): return "该线路拒绝访问，可能受线路或地区限制，请换线路"
        case .http(429): return "请求过于频繁，请稍后重试"
        case .http(let status): return "接口请求失败（HTTP \(status)）"
        }
    }
}
