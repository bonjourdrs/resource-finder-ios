import Foundation
#if canImport(Combine)
import Combine
#endif

@MainActor final class ProviderAccessStore {
    static let shared = ProviderAccessStore()
    #if canImport(Combine)
    let objectWillChange = ObservableObjectPublisher()
    #endif
    private let defaults: UserDefaults
    private var records: [String: ProviderObservation]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = (try? JSONDecoder().decode([String: ProviderObservation].self, from: defaults.data(forKey: "provider.access.v1") ?? Data())) ?? [:]
    }
    func enabled(_ id: String) -> Bool { defaults.object(forKey: "provider.enabled." + id) as? Bool ?? true }
    func setEnabled(_ id: String, _ enabled: Bool) {
        changed(); defaults.set(enabled, forKey: "provider.enabled." + id)
    }
    func observation(_ id: String) -> ProviderObservation { records[id] ?? ProviderObservation() }
    func catalog(_ id: String, query: String, count: Int? = nil, error: Error? = nil) {
        var value = observation(id)
        value.catalog = AccessObservation(state: error == nil ? .resolved : .failed,
            detail: error?.localizedDescription ?? "检索“\(query.prefix(40))”返回 \(count ?? 0) 条", checkedAt: Date())
        save(id, value)
    }
    func media(_ selection: MediaSelection, error: Error? = nil) {
        var value = observation(selection.work.providerID)
        let unsupported: Bool
        if let catalog = error as? CatalogError { switch catalog { case .unsupportedMedia, .unsupportedHeaders: unsupported = true; default: unsupported = false } } else { unsupported = false }
        value.media = AccessObservation(state: error == nil ? .resolved : unsupported ? .unsupported : .failed,
            detail: "\(selection.work.title.prefix(50)) · \(selection.episode.name)：" + (error?.localizedDescription ?? "地址可解析，未验证整片播放"), checkedAt: Date())
        save(selection.work.providerID, value)
    }
    private func changed() {
        #if canImport(Combine)
        objectWillChange.send()
        #endif
    }
    private func save(_ id: String, _ record: ProviderObservation) {
        changed(); records[id] = record
        defaults.set(try? JSONEncoder().encode(records), forKey: "provider.access.v1")
    }
}
#if canImport(Combine)
extension ProviderAccessStore: ObservableObject {}
#endif
