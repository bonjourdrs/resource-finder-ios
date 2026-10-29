import Foundation
import Darwin

struct TVDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
    let transport: URL
    let transportType: String
    let rendering: URL?
    let renderingType: String?
}
struct TVStatus { let state: String; let position: Double; let duration: Double }
enum DLNAError: LocalizedError {
    case invalidDevice, discovery, command(String)
    var errorDescription: String? {
        switch self {
        case .invalidDevice: return "不是有效的局域网 DLNA 电视设备地址"
        case .discovery: return "未能搜索电视。请检查同一 Wi-Fi、局域网权限和组播签名权限，或手动添加设备地址。"
        case .command(let message): return message
        }
    }
}
final class TVXML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String; var text = ""; var children: [Node] = []
        init(_ name: String) { self.name = name }
        func first(_ name: String) -> Node? { if self.name == name { return self }; return children.lazy.compactMap { $0.first(name) }.first }
        func all(_ name: String) -> [Node] { (self.name == name ? [self] : []) + children.flatMap { $0.all(name) } }
        func value(_ name: String) -> String { first(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }
    private var stack: [Node] = []; private var root: Node?
    static func parse(_ data: Data) throws -> Node {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8), !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw DLNAError.invalidDevice }
        let delegate = TVXML(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), let node = delegate.root else { throw DLNAError.invalidDevice }; return node
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let node = Node(name); stack.last?.children.append(node); if root == nil { root = node }; stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;") }
    static func seconds(_ value: String) -> Double {
        let p = value.split(separator: ":"); guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let s = Double(p[2]), h >= 0, m >= 0, m < 60, s >= 0, s < 60 else { return 0 }
        let result = h * 3600 + m * 60 + s; return result.isFinite ? result : 0
    }
    static func time(_ value: Double) -> String { let s = Int(value.isFinite ? max(0, min(value, 3_600_000)) : 0); return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
}
/// DLNA commands are confined to a user-selected private IPv4 peer. Device XML
/// cannot redirect commands to another host or load XML external entities.
@MainActor final class DLNAClient: NSObject, URLSessionTaskDelegate {
    private let allowLoopback: Bool
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.urlCache = nil; c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 5; c.timeoutIntervalForResource = 8
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    init(allowLoopback: Bool = false) { self.allowLoopback = allowLoopback }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    nonisolated static func privateAddress(_ value: String, allowLoopback: Bool = false) -> Bool {
        let a = value.split(separator: ".").compactMap { UInt8($0) }; guard a.count == 4, a.map(String.init).joined(separator: ".") == value else { return false }
        return a[0] == 10 || (a[0] == 172 && (16...31).contains(a[1])) || (a[0] == 192 && a[1] == 168) || (a[0] == 169 && a[1] == 254) || (allowLoopback && a[0] == 127)
    }
    private func check(_ url: URL, peer: String? = nil) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, Self.privateAddress(host, allowLoopback: allowLoopback), url.user == nil, url.password == nil, peer == nil || peer == host else { throw DLNAError.invalidDevice }
    }
    func device(at url: URL) async throws -> TVDevice {
        try check(url)
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw DLNAError.invalidDevice }
        return try Self.device(data, at: url, allowLoopback: allowLoopback)
    }
    static func device(_ data: Data, at url: URL, allowLoopback: Bool = false) throws -> TVDevice {
        guard let host = url.host, privateAddress(host, allowLoopback: allowLoopback) else { throw DLNAError.invalidDevice }
        let root = try TVXML.parse(data)
        guard let renderer = root.all("device").first(where: { $0.value("deviceType").contains(":MediaRenderer:") }) else { throw DLNAError.invalidDevice }
        let base = URL(string: root.value("URLBase"), relativeTo: url)?.absoluteURL ?? url
        guard base.host == host, ["http", "https"].contains(base.scheme ?? "") else { throw DLNAError.invalidDevice }
        var av: URL?, avType: String?, render: URL?, renderType: String?
        for service in renderer.all("service") {
            let type = service.value("serviceType"), reference = service.value("controlURL")
            guard !reference.isEmpty, let control = URL(string: reference, relativeTo: base)?.absoluteURL, control.host == host, ["http", "https"].contains(control.scheme ?? ""), control.user == nil, control.password == nil else { continue }
            if type.hasPrefix("urn:schemas-upnp-org:service:AVTransport:") { av = control; avType = type }
            if type.hasPrefix("urn:schemas-upnp-org:service:RenderingControl:") { render = control; renderType = type }
        }
        guard let av, let avType else { throw DLNAError.invalidDevice }
        let name = renderer.value("friendlyName"), id = renderer.value("UDN")
        return TVDevice(id: id.isEmpty ? host : id, name: name.isEmpty ? host : name, address: host, transport: av, transportType: avType, rendering: render, renderingType: renderType)
    }
    nonisolated static func location(_ packet: String, peer: String) -> URL? {
        guard packet.utf8.count <= 16_384, packet.hasPrefix("HTTP/1.1 200"), privateAddress(peer) else { return nil }
        let value = packet.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("location:") }.map { String($0.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
        guard let value, let url = URL(string: value), url.host == peer, ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { return nil }; return url
    }
    func discover() async throws -> [TVDevice] {
        let locations: [URL] = try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else { c.resume(throwing: DLNAError.discovery); return }
                defer { Darwin.close(fd) }
                var timeout = timeval(tv_sec: 0, tv_usec: 350_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr.s_addr = INADDR_ANY
                let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                guard bound == 0 else { c.resume(throwing: DLNAError.discovery); return }
                address.sin_port = UInt16(1900).bigEndian; inet_pton(AF_INET, "239.255.255.250", &address.sin_addr)
                let bytes = Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n".utf8)
                var sent = false
                for _ in 0..<2 {
                    let n = bytes.withUnsafeBytes { buffer in withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
                    sent = sent || n == bytes.count
                }
                guard sent else { c.resume(throwing: DLNAError.discovery); return }
                let deadline = Date().addingTimeInterval(6.5); var locations = Set<URL>(); var buffer = [UInt8](repeating: 0, count: 16_384)
                while Date() < deadline && locations.count < 32 {
                    var peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let count = buffer.withUnsafeMutableBytes { raw in withUnsafeMutablePointer(to: &peer) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length) } } }
                    if count > 0 {
                        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN)); inet_ntop(AF_INET, &peer.sin_addr, &host, socklen_t(host.count))
                        if let url = Self.location(String(decoding: buffer.prefix(count), as: UTF8.self), peer: String(cString: host)) { locations.insert(url) }
                    }
                }
                c.resume(returning: Array(locations))
            }
        }
        try Task.checkCancellation()
        var devices: [TVDevice] = []
        for location in locations {
            try Task.checkCancellation()
            if let device = try? await device(at: location), !devices.contains(where: { $0.id == device.id }) { devices.append(device) }
        }
        return devices
    }
    func action(_ tv: TVDevice, _ name: String, arguments: [(String, String)] = [], rendering: Bool = false) async throws -> TVXML.Node {
        guard let url = rendering ? tv.rendering : tv.transport, let type = rendering ? tv.renderingType : tv.transportType else { throw DLNAError.command("电视不支持音量控制") }
        try check(url, peer: tv.address)
        let args = [("InstanceID", "0")] + arguments
        let body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(name) xmlns:u=\"\(TVXML.escape(type))\">" + args.map { "<\($0.0)>\(TVXML.escape($0.1))</\($0.0)>" }.joined() + "</u:\(name)></s:Body></s:Envelope>"
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type"); request.setValue("\"\(type)#\(name)\"", forHTTPHeaderField: "SOAPACTION")
        let (data, response) = try await session.data(for: request), root = try TVXML.parse(data)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), root.first("Fault") == nil else { throw DLNAError.command("电视拒绝 \(name)：\(root.value("errorDescription")) \(root.value("errorCode"))") }
        return root
    }
    func load(_ tv: TVDevice, url: URL, title: String, kind: MediaKind) async throws {
        let type = kind == .hls ? "application/vnd.apple.mpegurl" : "video/mp4"
        let metadata = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"1\" parentID=\"0\" restricted=\"1\"><dc:title>\(TVXML.escape(title))</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo=\"http-get:*:\(type):*\">\(TVXML.escape(url.absoluteString))</res></item></DIDL-Lite>"
        _ = try await action(tv, "SetAVTransportURI", arguments: [("CurrentURI", url.absoluteString), ("CurrentURIMetaData", metadata)])
        _ = try await action(tv, "Play", arguments: [("Speed", "1")])
    }
    func status(_ tv: TVDevice) async throws -> TVStatus {
        let t = try await action(tv, "GetTransportInfo"), p = try await action(tv, "GetPositionInfo")
        return TVStatus(state: t.value("CurrentTransportState"), position: TVXML.seconds(p.value("RelTime")), duration: TVXML.seconds(p.value("TrackDuration")))
    }
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&list) == 0 else { return nil }; defer { freeifaddrs(list) }
        var cursor = list
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == "en0", let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
    func close() { session.invalidateAndCancel() }
}
