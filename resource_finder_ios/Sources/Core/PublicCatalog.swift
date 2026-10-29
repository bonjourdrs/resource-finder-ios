import Foundation
import SwiftSoup
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

struct ProviderEpisode: Sendable {
    let episode: VideoEpisode
    let url: URL?
    let kind: MediaKind?
}
struct ProviderLine: Sendable { let line: VideoLine; let episodes: [ProviderEpisode] }
struct ProviderWork: Sendable { let work: VideoWork; let lines: [ProviderLine] }
struct ProviderSearch: Sendable { let works: [VideoWork]; let more: Bool; var nextURL: URL? = nil }
enum PublicCatalogParser {
    static func publicHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let rawHost = url.host?.lowercased(), !rawHost.contains(":"), !rawHost.hasPrefix("127."), !rawHost.hasPrefix("10."), rawHost.contains("."), url.user == nil, url.password == nil,
              !rawHost.hasSuffix(".local"), !rawHost.hasSuffix(".internal"), !rawHost.hasSuffix(".localhost"), rawHost != "localhost." else { return false }
        let numbers = rawHost.split(separator: ".").compactMap { Int($0) }
        if numbers.count == 4 {
            if [0, 10, 127].contains(numbers[0]) || (numbers[0] == 192 && numbers[1] == 168) || (numbers[0] == 169 && numbers[1] == 254) || (numbers[0] == 172 && (16...31).contains(numbers[1])) { return false }
        }
        return true
    }
    static func number(_ name: String) -> Int? {
        guard let groups = matches(#"^(?:第\s*)?(\d{1,4})\s*(?:集|话|期)?$"#, name.trimmingCharacters(in: .whitespacesAndNewlines)).first else { return nil }
        return Int(groups[1])
    }
    static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }
    static func clean(_ value: String) -> String { (try? SwiftSoup.parse(value).text()) ?? value }
    static func digest(_ label: String) -> String { SHA256.hash(data: Data(label.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() }
    static func nativeKind(_ value: String, flag: String = "") -> MediaKind? {
        guard let url = URL(string: value), publicHTTPS(url) else { return nil }
        if url.path.lowercased().hasSuffix(".mp4") { return .progressive }
        if url.path.lowercased().hasSuffix(".m3u8") || flag.lowercased().contains("m3u8") { return .hls }
        return nil
    }
    static func unsupported(_ value: String) -> String {
        if value.isEmpty { return "播放地址为空，暂不支持" }
        if value.hasPrefix("http://") { return "此来源的 HTTP 线路暂未适配" }
        return "网页解析、专用协议或其他格式，暂不支持"
    }
    static func json(_ body: String) throws -> [String: Any] {
        guard let result = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              (integer(result["code"]) ?? 1) == 1, result["list"] is [Any] else { throw CatalogError.message("目录未返回有效 JSON 列表，可重试") }
        return result
    }
    static func string(_ value: Any?) -> String { if let s = value as? String { return s }; if let n = value as? NSNumber { return n.stringValue }; return "" }
    static func integer(_ value: Any?) -> Int? { Int(string(value)) }
    static func model(_ row: [String: Any], _ config: ProviderConfig) -> VideoWork? {
        guard let id = Int64(string(row["vod_id"])), id > 0 else { return nil }
        let title = clean(string(row["vod_name"])); guard !title.isEmpty else { return nil }
        let poster = string(row["vod_pic"])
        return VideoWork(id: id, title: title, year: integer(row["vod_year"]), kind: string(row["type_name"]), synopsis: clean(string(row["vod_content"])), posterURL: URL(string: poster).map(publicHTTPS) == true ? poster : nil, remarks: string(row["vod_remarks"]), sourceID: config.id)
    }
    static func searchJSON(_ body: String, config: ProviderConfig, page: Int) throws -> ProviderSearch {
        let root = try json(body), rows = (root["list"] as? [[String: Any]]) ?? []
        var seen = Set<Int64>()
        return ProviderSearch(works: rows.compactMap { model($0, config) }.filter { seen.insert($0.id).inserted }, more: !rows.isEmpty && page < (integer(root["pagecount"]) ?? page))
    }
    static func detailJSON(_ body: String, config: ProviderConfig, id: Int64) throws -> ProviderWork {
        let rows = try json(body)["list"] as? [[String: Any]] ?? []
        let matched = rows.filter { Int64(string($0["vod_id"])) == id }
        guard matched.count == 1, let row = matched.first, let work = model(row, config) else { throw CatalogError.mismatchedMedia }
        let flags = string(row["vod_play_from"]).components(separatedBy: "$$$")
        let groups = string(row["vod_play_url"]).components(separatedBy: "$$$")
        guard flags.count == groups.count else { throw CatalogError.message("线路分组不一致，请重试") }
        var repetitions: [String: Int] = [:]
        let lines = flags.enumerated().map { index, flag -> ProviderLine in
            let ordinal = repetitions[flag, default: 0]; repetitions[flag] = ordinal + 1
            var labels: [String: Int] = [:]
            var episodes: [ProviderEpisode] = []
            for entry in groups[index].components(separatedBy: "#") {
                guard let separator = entry.firstIndex(of: "$") else { continue }
                let label = clean(String(entry[..<separator])); guard !label.isEmpty else { continue }
                let address = String(entry[entry.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let kind = nativeKind(address, flag: flag)
                let identity = (kind == nil ? "unsupported:" : "") + label
                let duplicate = labels[identity, default: 0]; labels[identity] = duplicate + 1
                let key = (kind == nil ? "u:" : "") + digest(label) + ":\(duplicate)"
                episodes.append(ProviderEpisode(episode: VideoEpisode(key: key, index: episodes.count, name: label, number: number(label), unsupportedReason: kind == nil ? unsupported(address) : nil), url: URL(string: address), kind: kind))
            }
            let reason: String? = episodes.isEmpty ? "该线路暂无选集" : episodes.allSatisfy { $0.kind == nil } ? "该线路尚无已适配的直连格式" : nil
            return ProviderLine(line: VideoLine(key: "\(flag):\(ordinal)", name: "线路 \(index + 1)", episodeCount: episodes.count, entitlementRequired: false, unsupportedReason: reason), episodes: episodes)
        }
        return ProviderWork(work: work, lines: lines)
    }
    static func searchKKYS(_ body: String, base: URL) throws -> ProviderSearch {
        let doc = try SwiftSoup.parse(body, base.absoluteString)
        var items: [VideoWork] = [], seen = Set<Int64>()
        for card in try doc.select("a.search-result-item[href]").array() {
            guard let url = URL(string: try card.absUrl("href")), let match = matches(#"^/detail/(\d+)\.html$"#, url.path).first, let id = Int64(match[1]), seen.insert(id).inserted else { continue }
            let title = try card.select(".title").text(); guard !title.isEmpty else { continue }
            let tags = try card.select(".tags span").array().map { try $0.text() }
            let image = try card.select("img").first()
            let original = try image?.attr("data-original")
            let poster = original?.isEmpty == false ? original : try image?.attr("src")
            items.append(VideoWork(id: id, title: title, year: tags.first.flatMap(Int.init), kind: try card.select(".search-result-item-header").text(), posterURL: poster.flatMap { URL(string: $0, relativeTo: base)?.absoluteString }, sourceID: "kkys"))
        }
        var next: URL?
        for a in try doc.select("a[href]").array() {
            let label = try a.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if try a.attr("rel") == "next" || ["下一页", "下页", "下一页 >", "下一页>"].contains(label), let candidate = URL(string: try a.absUrl("href")), candidate.host == base.host, candidate.path == "/search" { next = candidate; break }
        }
        return ProviderSearch(works: items, more: next != nil, nextURL: next)
    }
    static func detailKKYS(_ body: String, base: URL, id: Int64) throws -> ProviderWork {
        let doc = try SwiftSoup.parse(body, base.absoluteString)
        let title = try doc.select("h1").text()
        let names = try doc.select(".source-item").array().map { try $0.text() }
        var lines: [ProviderLine] = [], seen = Set<String>()
        for (position, group) in try doc.select(".episode-list").array().enumerated() {
            var episodes: [ProviderEpisode] = [], keys = Set<String>()
            for a in try group.select("a[href]").array() {
                guard let link = URL(string: try a.absUrl("href")), let match = matches(#"^/play/(\d+)-(\d+)-([0-9-]+)\.html$"#, link.path).first, Int64(match[1]) == id else { continue }
                let key = String(link.lastPathComponent.dropLast(5)), label = try a.text()
                guard !label.isEmpty, keys.insert(key).inserted else { continue }
                episodes.append(ProviderEpisode(episode: VideoEpisode(key: key, index: episodes.count, name: label, number: number(label)), url: link, kind: nil))
            }
            guard let first = episodes.first, first.episode.key.split(separator: "-").count >= 3 else { continue }
            let provider = String(first.episode.key.split(separator: "-")[1]), key = provider + ":" + first.episode.key
            guard seen.insert(key).inserted else { continue }
            lines.append(ProviderLine(line: VideoLine(key: key, name: position < names.count ? names[position] : "线路 \(provider)", episodeCount: episodes.count, entitlementRequired: false), episodes: episodes))
        }
        guard !lines.isEmpty else { throw CatalogError.message("可可暂未返回可用选集，请刷新目录") }
        let priority = ["37", "9", "3", "21", "7", "36", "33", "19", "14"]
        lines.sort { (priority.firstIndex(of: String($0.line.key.split(separator: ":")[0])) ?? 100) < (priority.firstIndex(of: String($1.line.key.split(separator: ":")[0])) ?? 100) }
        let summary = try doc.select(".detail-desc,.detail-description").text()
        return ProviderWork(work: VideoWork(id: id, title: title, summary: summary, sourceID: "kkys"), lines: lines)
    }
    static func mediaKKYS(_ body: String, base: URL) throws -> PlaybackSource {
        guard let match = matches(#"const\s+playSource\s*=\s*\{\s*src:\s*("(?:[^"\\]|\\.)*")\s*,\s*type:\s*['"]([^'"]+)"#, body).first,
              let raw = try? JSONDecoder().decode(String.self, from: Data(match[1].utf8)), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !["null", "undefined"].contains(raw.lowercased()), let url = URL(string: raw, relativeTo: base)?.absoluteURL, publicHTTPS(url) else { throw CatalogError.message("该线路播放地址为空或无效，请换线路") }
        let kind: MediaKind
        switch match[2].lowercased() { case "application/x-mpegurl", "application/vnd.apple.mpegurl": kind = .hls; case "video/mp4": kind = .progressive; default: throw CatalogError.unsupportedMedia }
        return PlaybackSource(url: url, kind: kind)
    }
}
