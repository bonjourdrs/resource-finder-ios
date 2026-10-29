import Foundation
@testable import ProviderCore

@main struct ProviderProbe {
    @MainActor static func main() async {
        var results: [[String: Any]] = []
        for config in ProviderRegistry.all where config.id != "jianpian" {
            var record: [String: Any] = ["source": config.id, "experimental": config.experimental, "media_bytes_requested": false]
            do {
                let provider = PublicCatalogProvider(config: config)
                let page = try await provider.search("流浪地球", page: 1)
                record["search_count"] = page.works.count
                if let work = page.works.first(where: { $0.title == "流浪地球" && $0.year == 2019 }) {
                    let detail = try await provider.work(work.id)
                    record["matched"] = true; record["line_count"] = detail.lines.count
                    record["unsupported_lines"] = detail.lines.filter { !$0.line.playable }.count
                    if !config.experimental, let line = detail.lines.first(where: { $0.line.playable }), let episode = line.episodes.first(where: { $0.episode.unsupportedReason == nil }) {
                        let source = try await provider.resolve(MediaSelection(work: detail.work, episode: episode.episode, lineKey: line.line.key))
                        record["descriptor"] = source.kind.rawValue; record["resolved"] = true
                    }
                } else { record["matched"] = false }
            } catch { record["error"] = error.localizedDescription }
            results.append(record)
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
        }
        let report: [String: Any] = ["observed_at": ISO8601DateFormatter().string(from: Date()), "device_playback_tested": false, "results": results]
        try? FileManager.default.createDirectory(atPath: "build", withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: "build/provider-probe.json")) }
        let expected = results.filter { $0["experimental"] as? Bool == false }
        exit(expected.count == 4 && expected.allSatisfy { $0["resolved"] as? Bool == true } ? 0 : 1)
    }
}
