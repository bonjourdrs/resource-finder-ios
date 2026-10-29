import Foundation
#if canImport(Combine)
import Combine
#endif

struct WatchRecord: Codable, Identifiable {
    let selection: MediaSelection
    var position: Double
    var duration: Double
    var updatedAt: Date
    var id: String { selection.work.sourceKey }
}
@MainActor final class WatchStore {
    #if canImport(Combine)
    @Published private(set) var records: [WatchRecord]
    #else
    private(set) var records: [WatchRecord]
    #endif
    private let defaults: UserDefaults
    private var suppressed = Set<String>()
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = (try? JSONDecoder().decode([WatchRecord].self, from: defaults.data(forKey: "watch.v1") ?? Data())) ?? []
    }
    func begin(_ selection: MediaSelection) { suppressed.remove(selection.work.sourceKey) }
    func save(_ selection: MediaSelection, position: Double, duration: Double) {
        guard !suppressed.contains(selection.work.sourceKey), position.isFinite, position >= 0,
              duration.isFinite, duration > 0 else { return }
        records.removeAll { $0.id == selection.work.sourceKey }
        records.insert(WatchRecord(selection: selection, position: min(position, duration), duration: duration, updatedAt: Date()), at: 0)
        records = Array(records.prefix(100)); persist()
    }
    func resumePosition(_ selection: MediaSelection) -> Double {
        guard let record = records.first(where: { $0.id == selection.work.sourceKey && $0.selection.episode.key == selection.episode.key && $0.selection.lineKey == selection.lineKey }),
              record.position < record.duration * 0.95, record.duration - record.position > 5 else { return 0 }
        return record.position
    }
    func remove(_ id: String) { suppressed.insert(id); records.removeAll { $0.id == id }; persist() }
    func remove(_ id: Int64) { remove("jp:\(id)") }
    func clear() { suppressed.formUnion(records.map(\.id)); records = []; persist() }
    private func persist() { defaults.set(try? JSONEncoder().encode(records), forKey: "watch.v1") }
}

#if canImport(Combine)
extension WatchStore: ObservableObject {}
#endif
