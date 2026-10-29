import AVFoundation
import Combine
import CryptoKit
import UIKit

enum DownloadState: String, Codable {
    case queued, resolving, transferring, paused, complete, failed
    var label: String {
        switch self {
        case .queued: return "等待下载"
        case .resolving: return "正在获取地址"
        case .transferring: return "正在下载"
        case .paused: return "已暂停"
        case .complete: return "已下载"
        case .failed: return "需要重试"
        }
    }
    var active: Bool { self == .resolving || self == .transferring }
}
struct DownloadEntry: Codable, Identifiable {
    let selection: MediaSelection
    var state: DownloadState = .queued
    var progress: Double = 0
    var bytes: Int64 = 0
    var expectedBytes: Int64 = 0
    var error: String?
    var localPath: String?
    var localBookmark: Data?
    var keyCount: Int?
    var portableHLS: Bool?
    var kind: MediaKind = .progressive
    var attempt = UUID()
    var createdAt = Date()
    var id: String { selection.id }
}
private struct TaskMarker: Codable { let id: String; let attempt: UUID; var component: String? = nil }
enum DownloadFailure: LocalizedError {
    case missing, incomplete, storage, unsupported, inUse, http(Int)
    var errorDescription: String? {
        switch self {
        case .missing: return "离线文件已不存在，请重新下载"
        case .incomplete: return "离线媒体不完整，请重新下载；不会自动使用网络播放"
        case .storage: return "无法保存下载文件，请检查可用空间后重试"
        case .unsupported: return "该线路暂不支持下载，请换线路"
        case .inUse: return "该下载正在播放，请关闭播放器后删除"
        case .http(let code): return "下载失败（HTTP \(code)），可重新获取地址重试"
        }
    }
}
/// Holds the system completion until asynchronous media validation is persisted.
@MainActor final class DownloadBackgroundBridge {
    static let shared = DownloadBackgroundBridge()
    private var handlers: [String: [() -> Void]] = [:]
    private var finished = Set<String>()
    private var pending: [String: Int] = [:]
    func register(_ id: String, handler: @escaping () -> Void) { handlers[id, default: []].append(handler); drain(id) }
    func begin(_ id: String) { pending[id, default: 0] += 1 }
    func end(_ id: String) { pending[id] = max(0, pending[id, default: 0] - 1); drain(id) }
    func finish(_ id: String) {
        // Foreground deliveries have no UIApplication completion. Do not retain
        // their finish event and accidentally complete a future background batch.
        guard handlers[id]?.isEmpty == false else { finished.remove(id); return }
        finished.insert(id); drain(id)
    }
    private func drain(_ id: String) {
        if finished.contains(id), pending[id, default: 0] == 0, let callbacks = handlers.removeValue(forKey: id) {
            finished.remove(id); callbacks.forEach { $0() }
        }
    }
}
@MainActor final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()
    @Published private(set) var entries: [DownloadEntry] = []
    @Published private(set) var storageError: String?
    @Published private(set) var restored = false
    private let root: URL
    private let namespace: String
    private var service: (any CatalogService)?
    private var events: DownloadEvents!
    private var files: URLSession!
    private var streams: AVAssetDownloadURLSession!
    private var tasks: [String: URLSessionTask] = [:]
    private var resolvers: [String: Task<Void, Never>] = [:]
    private var leases: [String: UIBackgroundTaskIdentifier] = [:]
    private var finalizing = Set<String>()
    private var assetLocations: [UUID: URL] = [:]
    private var protectedIDs = Set<String>()
    private var castProtectedIDs = Set<String>()
    private var hlsJobs: [String: HLSCacheJob] = [:]
    private var hlsTasks: [String: [String: URLSessionTask]] = [:]
    private var hlsProgress: [String: [String: (Int64, Int64)]] = [:]
    private var activated = false
    private var lastProgressSave = Date.distantPast
    private var metadataValid = true
    var allowsCellular: Bool {
        get { UserDefaults.standard.bool(forKey: "downloads.cellular") }
        set { UserDefaults.standard.set(newValue, forKey: "downloads.cellular") }
    }
    init(root: URL? = nil, namespace: String = "com.resourcefinder.ios.downloads.v1") {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        self.namespace = namespace
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            var folder = self.root
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            if FileManager.default.fileExists(atPath: metadata.path) {
                entries = try JSONDecoder().decode([DownloadEntry].self, from: Data(contentsOf: metadata))
            }
        } catch { metadataValid = false; storageError = "下载目录或任务记录无法读取，请检查存储空间。" }
    }
    private var metadata: URL { root.appendingPathComponent("tasks.json") }
    func configure(service: any CatalogService) { self.service = service; activate() }
    func activate() {
        guard !activated else { return }; activated = true
        events = DownloadEvents(owner: self)
        func configuration(_ suffix: String) -> URLSessionConfiguration {
            let value = URLSessionConfiguration.background(withIdentifier: namespace + suffix)
            value.sessionSendsLaunchEvents = true; value.isDiscretionary = false
            value.waitsForConnectivity = true; value.allowsCellularAccess = allowsCellular
            value.timeoutIntervalForResource = 7 * 24 * 3600
            return value
        }
        files = URLSession(configuration: configuration(".files"), delegate: events, delegateQueue: .main)
        streams = AVAssetDownloadURLSession(configuration: configuration(".hls"), assetDownloadDelegate: events, delegateQueue: .main)
        Task { await reconcile() }
    }
    private func allTasks(_ session: URLSession) async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in session.getAllTasks { continuation.resume(returning: $0) } }
    }
    private func reconcile() async {
        let fileTasks = await allTasks(files)
        let streamTasks = await allTasks(streams)
        let existing = fileTasks + streamTasks
        for task in existing {
            guard let marker = marker(task), let entry = entries.first(where: { $0.id == marker.id && $0.attempt == marker.attempt }), entry.state != .complete else { task.cancel(); continue }
            guard let currentEntry = entries.first(where: { $0.id == entry.id && $0.attempt == entry.attempt }) else {
                task.cancel(); continue
            }
            if let component = marker.component {
                guard entry.portableHLS == true, let job = try? HLSCacheJob.read(hlsFolder(entry), attempt: entry.attempt), job.resources.contains(where: { $0.name == component }) else { task.cancel(); continue }
                hlsJobs[entry.id] = job; hlsTasks[entry.id, default: [:]][component] = task
                if currentEntry.state == .paused { task.suspend() }
                else if currentEntry.state.active { update(entry.id) { $0.state = .transferring }; task.resume() }
                else { task.cancel(); hlsTasks[entry.id]?.removeValue(forKey: component) }
                continue
            }
            tasks[entry.id] = task
            if currentEntry.state == .paused { task.suspend() }
            else if currentEntry.state.active { update(entry.id) { $0.state = .transferring }; task.resume() }
            else { task.cancel(); tasks.removeValue(forKey: entry.id) }
        }
        for entry in entries where entry.portableHLS == true && (entry.state.active || entry.state == .paused) {
            if hlsJobs[entry.id] == nil { hlsJobs[entry.id] = try? HLSCacheJob.read(hlsFolder(entry), attempt: entry.attempt) }
        }
        for entry in entries where entry.state.active && tasks[entry.id] == nil && entry.portableHLS != true {
            update(entry.id) { $0.state = .failed; $0.error = "任务已中断，点击重试继续下载" }
        }
        restored = true; persist()
        for entry in entries where entry.state.active && entry.portableHLS == true { scheduleHLS(entry.id) }
        pump()
    }
    @discardableResult func enqueue(_ selections: [MediaSelection]) -> Int {
        guard storageError == nil else { return 0 }
        var ids = Set(entries.map(\.id)), count = 0
        for selection in selections where ids.insert(selection.id).inserted {
            entries.append(DownloadEntry(selection: selection)); count += 1
        }
        persist(); activate(); pump(); return count
    }
    func pause(_ id: String, reason: String? = nil) {
        guard let entry = entries.first(where: { $0.id == id }), entry.state == .queued || entry.state.active else { return }
        resolvers.removeValue(forKey: id)?.cancel(); endLease(id)
        tasks[id]?.suspend(); hlsTasks[id]?.values.forEach { $0.suspend() }
        update(id) { $0.state = .paused; $0.error = reason }; persist(); pump()
    }
    func resume(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }), [.paused, .failed].contains(entry.state), !finalizing.contains(id) else { return }
        if entry.portableHLS == true, hlsJobs[id] != nil, entry.state == .paused {
            update(id) { $0.state = .queued; $0.error = nil }
        } else if let task = tasks[id], task.state == .suspended {
            update(id) { $0.state = .queued; $0.error = nil }
        } else {
            tasks.removeValue(forKey: id)?.cancel(); cancelHLS(id)
            cleanLocal(entry)
            update(id) { $0.state = .queued; $0.attempt = UUID(); $0.error = nil; $0.progress = 0; $0.localPath = nil; $0.localBookmark = nil; $0.keyCount = nil; $0.portableHLS = nil; $0.bytes = 0 }
        }
        persist(); pump()
    }
    func remove(_ id: String) throws {
        guard !protectedIDs.contains(id), !castProtectedIDs.contains(id) else { throw DownloadFailure.inUse }
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }; persist()
        resolvers.removeValue(forKey: id)?.cancel(); endLease(id); tasks.removeValue(forKey: id)?.cancel()
        cancelHLS(id); cleanLocal(entry); persist(); pump()
    }
    func protect(_ id: String) { protectedIDs.insert(id) }
    func unprotect(_ id: String) { protectedIDs.remove(id) }
    func protectCast(_ id: String) { castProtectedIDs.insert(id) }
    func unprotectCast(_ id: String) { castProtectedIDs.remove(id) }
    func background() { persist() }
    func foreground() { persist(); pump() }
    private func pump() {
        guard restored, storageError == nil, let service else { return }
        var slots = max(0, 2 - entries.filter { $0.state.active || finalizing.contains($0.id) }.count)
        for entry in entries where entry.state == .queued && slots > 0 {
            slots -= 1
            if entry.portableHLS == true, hlsJobs[entry.id] != nil {
                update(entry.id) { $0.state = .transferring }; scheduleHLS(entry.id); continue
            }
            if let task = tasks[entry.id], task.state == .suspended {
                update(entry.id) { $0.state = .transferring }; task.resume(); continue
            }
            let id = entry.id, attempt = entry.attempt
            update(id) { $0.state = .resolving; $0.error = nil }
            leases[id] = UIApplication.shared.beginBackgroundTask(withName: "prepare-download") { [weak self] in
                Task { @MainActor in self?.pause(id, reason: "后台准备已暂停，打开应用后点继续") }
            }
            resolvers[id] = Task { [weak self] in
                guard let self else { return }
                defer { if current(id, attempt) { resolvers.removeValue(forKey: id); endLease(id) } }
                do {
                    let source = try await service.downloadSource(entry.selection)
                    try Task.checkCancellation()
                    guard current(id, attempt), entries.first(where: { $0.id == id })?.state == .resolving else { return }
                    guard ["http", "https"].contains(source.url.scheme?.lowercased() ?? "") else { throw DownloadFailure.unsupported }
                    let task: URLSessionTask
                    if source.kind == .hls {
                        let keys = try await HLSKeys.collect(source: source, allowsCellular: allowsCellular)
                        try Task.checkCancellation()
                        guard current(id, attempt), entries.first(where: { $0.id == id })?.state == .resolving else { return }
                        let keyURL = keyFile(entry)
                        try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try JSONEncoder().encode(keys).write(to: keyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                        update(id) { $0.keyCount = keys.count }
                        let job = try await PortableHLS.prepare(source: source, keys: keys, folder: hlsFolder(entry), attempt: attempt, allowsCellular: allowsCellular)
                        try Task.checkCancellation()
                        guard current(id, attempt), entries.first(where: { $0.id == id })?.state == .resolving else { return }
                        hlsJobs[id] = job
                        let home = NSHomeDirectory() + "/", path = hlsFolder(entry).appendingPathComponent(job.rootName).path
                        guard path.hasPrefix(home) else { throw DownloadFailure.storage }
                        update(id) { $0.kind = .hls; $0.portableHLS = true; $0.localPath = String(path.dropFirst(home.count)); $0.localBookmark = nil; $0.state = .transferring }
                        persist(); scheduleHLS(id); return
                    } else {
                        var request = URLRequest(url: source.url)
                        source.requestHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                        task = files.downloadTask(with: request)
                    }
                    try Task.checkCancellation()
                    guard current(id, attempt), entries.first(where: { $0.id == id })?.state == .resolving else { task.cancel(); return }
                    task.taskDescription = String(data: try JSONEncoder().encode(TaskMarker(id: id, attempt: attempt)), encoding: .utf8)
                    tasks[id] = task; update(id) { $0.state = .transferring; $0.kind = source.kind }; persist(); task.resume()
                } catch {
                    if !Task.isCancelled && current(id, attempt) {
                        update(id) { $0.state = .failed; $0.error = error.localizedDescription }; persist(); pump()
                    }
                }
            }
        }
        persist()
    }
    private func endLease(_ id: String) {
        if let lease = leases.removeValue(forKey: id), lease != .invalid { UIApplication.shared.endBackgroundTask(lease) }
    }
    private func marker(_ task: URLSessionTask) -> TaskMarker? {
        guard let text = task.taskDescription, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskMarker.self, from: data)
    }
    private func current(_ id: String, _ attempt: UUID) -> Bool { entries.contains { $0.id == id && $0.attempt == attempt } }
    private func update(_ id: String, _ change: (inout DownloadEntry) -> Void) {
        if let index = entries.firstIndex(where: { $0.id == id }) { change(&entries[index]) }
    }
    private func persist() {
        guard metadataValid else { return }
        do { try JSONEncoder().encode(entries).write(to: metadata, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); storageError = nil }
        catch { storageError = "任务记录保存失败，请检查存储空间后重新打开应用。" }
    }
    private func fileURL(_ entry: DownloadEntry) throws -> URL {
        if let bookmark = entry.localBookmark {
            var stale = false
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: home, bookmarkDataIsStale: &stale)
            guard url.isFileURL, url.pathExtension == "movpkg", try url.checkResourceIsReachable() else { throw DownloadFailure.missing }
            if stale, let refreshed = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: home) {
                update(entry.id) { $0.localBookmark = refreshed }; persist()
            }
            return url
        }
        guard let relative = entry.localPath, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw DownloadFailure.missing }
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(NSHomeDirectory() + "/"), FileManager.default.fileExists(atPath: url.path) else { throw DownloadFailure.missing }
        return url
    }
    private func cleanLocal(_ entry: DownloadEntry) {
        assetLocations.removeValue(forKey: entry.attempt)
        try? FileManager.default.removeItem(at: keyFile(entry))
        try? FileManager.default.removeItem(at: hlsFolder(entry))
        if let url = try? fileURL(entry), url.path.hasPrefix(root.path + "/") || url.pathExtension == "movpkg" { try? FileManager.default.removeItem(at: url) }
    }
    private func hlsFolder(_ entry: DownloadEntry) -> URL { root.appendingPathComponent("PortableHLS", isDirectory: true).appendingPathComponent(entry.attempt.uuidString, isDirectory: true) }
    private func keyFile(_ entry: DownloadEntry) -> URL { root.appendingPathComponent("Keys", isDirectory: true).appendingPathComponent(entry.attempt.uuidString + ".json") }
    private func rememberLocation(_ url: URL, task: URLSessionTask) {
        guard let marker = marker(task), current(marker.id, marker.attempt) else { return }
        if entries.first(where: { $0.id == marker.id })?.kind == .hls {
            // Keep AVFoundation's URL intact. System no-follow/file-reference
            // URLs are not ordinary sandbox path strings; bookmarks preserve
            // their identity without moving or interpreting the media package.
            assetLocations[marker.attempt] = url
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            if url.isFileURL, url.pathExtension == "movpkg",
               let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: home) {
                update(marker.id) { $0.localBookmark = bookmark }; persist()
            }
            return
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
        let absolute = url.baseURL == nil && !url.path.hasPrefix("/") ? home.appendingPathComponent(url.relativePath) : url.absoluteURL
        let resolved = absolute.standardizedFileURL.resolvingSymlinksInPath()
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            print("download-local-location: \(resolved.path); app-home: \(home.path)")
        }
        #endif
        guard resolved.isFileURL, resolved.path.hasPrefix(home.path + "/") else { return }
        update(marker.id) { $0.localPath = String(resolved.path.dropFirst(home.path.count + 1)) }; persist()
    }
    func offlineSource(_ id: String) async throws -> PlaybackSource {
        guard let entry = entries.first(where: { $0.id == id }), entry.state == .complete else { throw DownloadFailure.incomplete }
        do {
            let url = try fileURL(entry), asset = AVURLAsset(url: url)
            if entry.portableHLS == true {
                let job = try HLSCacheJob.read(hlsFolder(entry), attempt: entry.attempt)
                try job.validate(hlsFolder(entry))
                return PlaybackSource(url: url, kind: .hls, offline: true, offlineRoot: hlsFolder(entry))
            }
            if entry.kind == .hls {
                // Inspect cached media without loading encryption-dependent
                // properties on an asset that has no content-key session.
                let keys = try HLSKeys.read(keyFile(entry))
                guard let expected = entry.keyCount, keys.count == expected else { throw DownloadFailure.incomplete }
                guard asset.assetCache?.isPlayableOffline == true else { throw DownloadFailure.incomplete }
            } else {
                guard try await asset.load(.isPlayable) else { throw DownloadFailure.incomplete }
            }
            return PlaybackSource(url: url, kind: entry.kind, offline: true, offlineKeys: entry.kind == .hls ? keyFile(entry) : nil)
        } catch {
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }; persist(); throw error
        }
    }
    fileprivate func progress(_ task: URLSessionTask, fraction: Double?, bytes: Int64 = 0, expected: Int64 = 0) {
        guard let marker = marker(task), current(marker.id, marker.attempt) else { return }
        if let component = marker.component {
            hlsProgress[marker.id, default: [:]][component] = (bytes, expected); publishHLSProgress(marker.id); return
        }
        update(marker.id) {
            if let value = fraction, value.isFinite { $0.progress = min(0.99, max($0.progress, value)) }
            $0.bytes = max($0.bytes, bytes); $0.expectedBytes = max($0.expectedBytes, expected)
        }
        if Date().timeIntervalSince(lastProgressSave) >= 1 { lastProgressSave = Date(); persist() }
    }
    fileprivate func downloadedFile(_ task: URLSessionDownloadTask, location: URL) {
        guard let marker = marker(task), current(marker.id, marker.attempt) else { return }
        if let component = marker.component { downloadedHLSFile(task, marker: marker, component: component, location: location); return }
        do {
            guard let response = task.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw DownloadFailure.http((task.response as? HTTPURLResponse)?.statusCode ?? 0) }
            let folder = root.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = SHA256.hash(data: Data((marker.id + marker.attempt.uuidString).utf8)).map { String(format: "%02x", $0) }.joined()
            let destination = folder.appendingPathComponent(name + ".mp4")
            try FileManager.default.moveItem(at: location, to: destination)
            rememberLocation(destination, task: task)
        } catch { update(marker.id) { $0.error = error.localizedDescription }; persist() }
    }
    fileprivate func downloadedAsset(_ task: AVAssetDownloadTask, location: URL) { rememberLocation(location, task: task) }
    fileprivate func completed(_ session: URLSession, task: URLSessionTask, error: Error?) {
        guard let marker = marker(task), current(marker.id, marker.attempt) else { return }
        if let component = marker.component { completedHLS(marker, component: component, error: error); return }
        tasks.removeValue(forKey: marker.id)
        if let error {
            let value = error as NSError
            update(marker.id) {
                $0.state = .failed
                $0.error = value.domain == NSURLErrorDomain && value.code == NSURLErrorAppTransportSecurityRequiresSecureConnection ? DownloadFailure.unsupported.localizedDescription : value.code == NSURLErrorCancelled ? "下载已中断，点击重试" : error.localizedDescription
            }
            persist(); pump(); return
        }
        // Refresh the bookmark after the package has finished materializing.
        // Do not use destinationURL: newer download-task implementations may
        // return nil for that deprecated property despite its nonoptional type.
        if let assetTask = task as? AVAssetDownloadTask {
            if let location = assetLocations[marker.attempt] { rememberLocation(location, task: task) }
            else if assetTask.urlAsset.url.isFileURL { rememberLocation(assetTask.urlAsset.url, task: task) }
            assetLocations.removeValue(forKey: marker.attempt)
        }
        guard let entry = entries.first(where: { $0.id == marker.id }) else { return }
        if let message = entry.error {
            update(marker.id) { $0.state = .failed; $0.error = message }; persist(); pump(); return
        }
        let sessionID = session.configuration.identifier ?? namespace
        finalizing.insert(marker.id); DownloadBackgroundBridge.shared.begin(sessionID)
        Task {
            defer { finalizing.remove(marker.id); DownloadBackgroundBridge.shared.end(sessionID); pump() }
            do {
                if entry.error != nil { throw DownloadFailure.storage }
                if entry.kind == .hls {
                    let keys = try HLSKeys.read(keyFile(entry))
                    guard let expected = entry.keyCount, keys.count == expected else { throw DownloadFailure.incomplete }
                }
                let url = try fileURL(entry), asset = AVURLAsset(url: url)
                guard try await asset.load(.isPlayable), entry.kind != .hls || asset.assetCache?.isPlayableOffline == true else { throw DownloadFailure.incomplete }
                guard current(marker.id, marker.attempt) else { return }
                update(marker.id) { $0.state = .complete; $0.progress = 1; $0.error = nil }
            } catch {
                guard current(marker.id, marker.attempt) else { return }
                update(marker.id) { $0.state = .failed; $0.error = error.localizedDescription }
            }
            persist()
        }
    }
    private func cancelHLS(_ id: String) {
        hlsTasks.removeValue(forKey: id)?.values.forEach { $0.cancel() }
        hlsJobs.removeValue(forKey: id); hlsProgress.removeValue(forKey: id)
    }
    private func failHLS(_ id: String, _ error: Error) {
        cancelHLS(id); update(id) { $0.state = .failed; $0.error = error.localizedDescription }; persist(); pump()
    }
    private func scheduleHLS(_ id: String) {
        guard restored, let entry = entries.first(where: { $0.id == id }), entry.state == .transferring else { return }
        guard let job = hlsJobs[id] else { failHLS(id, DownloadFailure.incomplete); return }
        if job.finished { finishHLS(entry, job: job); return }
        let running = hlsTasks[id, default: [:]]
        var slots = max(0, 2 - running.count)
        for task in running.values where task.state == .suspended { task.resume() }
        for resource in job.resources where !resource.complete && running[resource.name] == nil && slots > 0 {
            slots -= 1
            var request = URLRequest(url: resource.url)
            job.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue(nil, forHTTPHeaderField: "Range"); request.allowsCellularAccess = allowsCellular
            let task = files.downloadTask(with: request)
            task.taskDescription = String(data: try! JSONEncoder().encode(TaskMarker(id: id, attempt: entry.attempt, component: resource.name)), encoding: .utf8)
            hlsTasks[id, default: [:]][resource.name] = task; task.resume()
        }
    }
    private func publishHLSProgress(_ id: String) {
        guard let job = hlsJobs[id] else { return }
        let active = hlsProgress[id, default: [:]]
        let completed = job.resources.filter(\.complete)
        let partial = active.values.reduce(0.0) { $0 + ($1.1 > 0 ? min(0.99, Double($1.0) / Double($1.1)) : 0) }
        update(id) {
            $0.progress = min(0.99, (Double(completed.count) + partial) / Double(max(1, job.resources.count)))
            $0.bytes = completed.reduce(0) { $0 + $1.bytes } + active.values.reduce(0) { $0 + $1.0 }
        }
    }
    private func downloadedHLSFile(_ task: URLSessionTask, marker: TaskMarker, component: String, location: URL) {
        guard let entry = entries.first(where: { $0.id == marker.id }), entry.state == .transferring,
              var job = hlsJobs[marker.id], let index = job.resources.firstIndex(where: { $0.name == component }) else { return }
        do {
            guard let response = task.response as? HTTPURLResponse, response.statusCode == 200 else { throw DownloadFailure.http((task.response as? HTTPURLResponse)?.statusCode ?? 0) }
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value > 0, !job.resources[index].key || size.int64Value == 16 else { throw DownloadFailure.incomplete }
            let destination = hlsFolder(entry).appendingPathComponent(component)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            job.resources[index].complete = true; job.resources[index].bytes = size.int64Value
            try job.save(hlsFolder(entry)); hlsJobs[marker.id] = job
            hlsProgress[marker.id]?.removeValue(forKey: component); publishHLSProgress(marker.id); persist()
        } catch { failHLS(marker.id, error) }
    }
    private func completedHLS(_ marker: TaskMarker, component: String, error: Error?) {
        hlsTasks[marker.id]?.removeValue(forKey: component)
        guard let entry = entries.first(where: { $0.id == marker.id }), entry.state == .transferring else { return }
        if let error { failHLS(marker.id, error); return }
        guard hlsJobs[marker.id]?.resources.first(where: { $0.name == component })?.complete == true else { failHLS(marker.id, DownloadFailure.incomplete); return }
        scheduleHLS(marker.id)
    }
    private func finishHLS(_ entry: DownloadEntry, job: HLSCacheJob) {
        guard !finalizing.contains(entry.id) else { return }
        finalizing.insert(entry.id)
        let sessionID = files.configuration.identifier ?? namespace
        DownloadBackgroundBridge.shared.begin(sessionID)
        Task {
            defer { finalizing.remove(entry.id); DownloadBackgroundBridge.shared.end(sessionID); pump() }
            var relay: MediaRelay?
            do {
                try job.validate(hlsFolder(entry))
                let source = PlaybackSource(url: hlsFolder(entry).appendingPathComponent(job.rootName), kind: .hls, offline: true, offlineKeys: keyFile(entry), offlineRoot: hlsFolder(entry))
                let proxy = try MediaRelay(source: source); relay = proxy
                let url = try await proxy.start(), asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                guard playable, duration.isFinite, duration > 0 else { throw DownloadFailure.incomplete }
                guard current(entry.id, entry.attempt), entries.first(where: { $0.id == entry.id })?.state == .transferring else { relay?.stop(); return }
                update(entry.id) { $0.state = .complete; $0.progress = 1; $0.error = nil }
                hlsJobs.removeValue(forKey: entry.id); hlsTasks.removeValue(forKey: entry.id); hlsProgress.removeValue(forKey: entry.id)
            } catch {
                if current(entry.id, entry.attempt) { update(entry.id) { $0.state = .failed; $0.error = error.localizedDescription } }
            }
            relay?.stop(); persist()
        }
    }
    func shutdown() { hlsTasks.values.forEach { $0.values.forEach { $0.cancel() } }; hlsTasks.removeAll(); files?.invalidateAndCancel(); streams?.invalidateAndCancel(); resolvers.values.forEach { $0.cancel() } }
}
private final class DownloadEvents: NSObject, AVAssetDownloadDelegate, URLSessionDownloadDelegate {
    weak var owner: DownloadCenter?
    init(owner: DownloadCenter) { self.owner = owner }
    // Both native sessions explicitly deliver their callbacks on OperationQueue.main.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated { owner?.downloadedFile(downloadTask, location: location) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated { owner?.progress(downloadTask, fraction: totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil, bytes: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated { owner?.downloadedAsset(assetDownloadTask, location: location) }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        MainActor.assumeIsolated { owner?.downloadedAsset(assetDownloadTask, location: location) }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        let expected = timeRangeExpectedToLoad.duration.seconds
        var intervals = loadedTimeRanges.map(\.timeRangeValue).map { ($0.start.seconds, $0.end.seconds) }.filter { $0.0.isFinite && $0.1.isFinite }.sorted { $0.0 < $1.0 }
        var seconds = 0.0
        while !intervals.isEmpty {
            var interval = intervals.removeFirst()
            while let next = intervals.first, next.0 <= interval.1 { interval.1 = max(interval.1, next.1); intervals.removeFirst() }
            seconds += max(0, interval.1 - interval.0)
        }
        MainActor.assumeIsolated { owner?.progress(assetDownloadTask, fraction: expected > 0 ? seconds / expected : nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { owner?.completed(session, task: task, error: error) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let id = session.configuration.identifier else { return }
        MainActor.assumeIsolated { DownloadBackgroundBridge.shared.finish(id) }
    }
}
@MainActor final class ResourceAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { PlayerOrientation.mask }
    static weak var downloadCenter: DownloadCenter?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        StoredKeyURLProtocol.install(); return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadBackgroundBridge.shared.register(identifier, handler: completionHandler)
        (Self.downloadCenter ?? DownloadCenter.shared).activate()
    }
}
