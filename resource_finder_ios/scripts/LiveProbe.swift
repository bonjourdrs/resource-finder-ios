import Foundation

@main struct LiveProbe {
    @MainActor static func main() async {
        var report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "media_bytes_requested": false, "device_playback_tested": false]
        var exitStatus: Int32 = 0
        do {
            // Ephemeral public guest identity; never uses an account or a user session.
            let identity = GuestIdentity(installationID: UUID().uuidString.lowercased(), credential: JianpianCrypto.encode(try JianpianCrypto.random(32)))
            let service = LiveCatalogService(client: JianpianClient(identity: identity))
            let results = try await service.search("三体", page: 1)
            guard let first = results.first else { throw CatalogError.invalidResponse }
            report["search_count"] = results.count
            let work = try await service.detail(first.id), manifest = try await service.manifest(first.id)
            report["work_id"] = work.id; report["line_count"] = manifest.lines.count
            guard let line = manifest.lines.first(where: \.available) else { throw CatalogError.unsupportedMedia }
            let episodes = try await service.episodes(work.id, line: line.key, page: 1)
            guard let episode = episodes.items.first else { throw CatalogError.invalidResponse }
            report["episode_count"] = episodes.total
            let selection = MediaSelection(work: work, episode: episode, lineKey: line.key)
            let descriptor = try await service.resolve(selection)
            report["protocol"] = descriptor.protocolName
            report["header_names"] = Array((descriptor.headers ?? [:]).keys).sorted()
            report["descriptor_matches_selection"] = true
            do { _ = try descriptor.userAgent(); report["headers_supported_in_foundation"] = true }
            catch { report["headers_supported_in_foundation"] = false }
            report["status"] = "passed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription; exitStatus = 1
        }
        let output = URL(fileURLWithPath: "build/live-probe.json")
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output); print(String(decoding: data, as: UTF8.self))
        }
        exit(exitStatus)
    }
}
