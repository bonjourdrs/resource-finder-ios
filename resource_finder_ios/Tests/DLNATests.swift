import XCTest
import Network
@testable import ResourceFinder

@MainActor final class DLNATests: XCTestCase {
    private func description(_ control: String = "/control") -> Data {
        Data("<root xmlns=\"urn:schemas-upnp-org:device-1-0\"><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>测试 &amp; TV</friendlyName><UDN>uuid:fixture-tv</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType><controlURL>\(control)</controlURL></service><service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/volume</controlURL></service></serviceList></device></root>".utf8)
    }
    func testDiscoveryAndDescriptionStayOnTheSelectedLANPeer() throws {
        let url = URL(string: "http://192.168.1.8:1234/description.xml")!
        let device = try DLNAClient.device(description(), at: url)
        XCTAssertEqual(device.name, "测试 & TV"); XCTAssertEqual(device.transport.absoluteString, "http://192.168.1.8:1234/control")
        XCTAssertEqual(device.transportType, "urn:schemas-upnp-org:service:AVTransport:2")
        XCTAssertThrowsError(try DLNAClient.device(description("http://example.com/control"), at: url))
        XCTAssertThrowsError(try DLNAClient.device(description(), at: URL(string: "http://8.8.8.8/desc")!))
        XCTAssertThrowsError(try TVXML.parse(Data("<!DOCTYPE a [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><a>&x;</a>".utf8)))
        let packet = "HTTP/1.1 200 OK\r\nLOCATION: \(url)\r\n\r\n"
        XCTAssertEqual(DLNAClient.location(packet, peer: "192.168.1.8"), url)
        XCTAssertNil(DLNAClient.location(packet, peer: "192.168.1.9"))
        XCTAssertFalse(DLNAClient.privateAddress("192.168.001.8"))
    }
    func testSOAPLoadSeekVolumeStatusAndFaultAgainstActualHTTPPeer() async throws {
        let server = try TVFixtureServer(description: description()); try await server.start(); defer { server.stop() }
        let client = DLNAClient(allowLoopback: true); defer { client.close() }
        let device = try await client.device(at: server.base.appendingPathComponent("description.xml"))
        let media = URL(string: "https://media.example/a.m3u8?x=1&y=2")!
        try await client.load(device, url: media, title: "A & <B>", kind: .hls)
        _ = try await client.action(device, "Seek", arguments: [("Unit", "REL_TIME"), ("Target", "00:01:23")])
        _ = try await client.action(device, "SetVolume", arguments: [("Channel", "Master"), ("DesiredVolume", "42")], rendering: true)
        let status = try await client.status(device)
        XCTAssertEqual(status.state, "PLAYING"); XCTAssertEqual(status.position, 83.5); XCTAssertEqual(status.duration, 120)
        do { _ = try await client.action(device, "Unsupported"); XCTFail("SOAP Fault must surface") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Seek unavailable")) }
        let requests = server.requests
        XCTAssertTrue(requests.contains { $0.contains("AVTransport:2#SetAVTransportURI") && $0.contains("x=1&amp;y=2") && $0.contains("A &amp;amp; &amp;lt;B&amp;gt;") })
        XCTAssertTrue(requests.contains { $0.contains("/volume HTTP/1.1") && $0.contains("<DesiredVolume>42</DesiredVolume>") })
    }
    func testTimeParsingAndEscaping() {
        XCTAssertEqual(TVXML.seconds("12:34:56.5"), 45296.5); XCTAssertEqual(TVXML.seconds("NOT_IMPLEMENTED"), 0)
        XCTAssertEqual(TVXML.seconds("nan:00:00"), 0); XCTAssertEqual(TVXML.time(83.5), "00:01:23")
    }
}

private final class TVFixtureServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rf.test.tv")
    private let description: Data
    private let lock = NSLock()
    private var logged: [String] = []
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return logged }
    private(set) var base: URL!
    init(description: Data) throws {
        self.description = description
        let p = NWParameters.tcp; p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any); listener = try NWListener(using: p)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !done else { return }
                if case .ready = state { done = true; base = URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!; c.resume() }
                if case .failed(let error) = state { done = true; c.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [weak self] conn in conn.start(queue: self!.queue); self?.receive(conn, bytes: Data()) }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, end, error in
            guard let self, error == nil else { connection.cancel(); return }; var bytes = bytes; if let data { bytes.append(data) }
            guard bytes.count < 262_144 else { connection.cancel(); return }
            if let delimiter = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: bytes[..<delimiter.lowerBound], as: UTF8.self)
                let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                if bytes.count >= delimiter.upperBound + length { respond(connection, text: String(decoding: bytes, as: UTF8.self)); return }
            }
            if !end { receive(connection, bytes: bytes) } else { connection.cancel() }
        }
    }
    private func respond(_ connection: NWConnection, text: String) {
        lock.lock(); logged.append(text); lock.unlock()
        var body: Data; var code = 200
        if text.hasPrefix("GET") { body = description }
        else {
            var value = "<ok/>"
            if text.contains("#GetTransportInfo") { value = "<CurrentTransportState>PLAYING</CurrentTransportState>" }
            if text.contains("#GetPositionInfo") { value = "<RelTime>00:01:23.5</RelTime><TrackDuration>00:02:00</TrackDuration>" }
            if text.contains("#Unsupported") { code = 500; value = "<s:Fault><errorCode>710</errorCode><errorDescription>Seek unavailable</errorDescription></s:Fault>" }
            body = Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>\(value)</s:Body></s:Envelope>".utf8)
        }
        let header = Data("HTTP/1.1 \(code) Response\r\nContent-Type: text/xml\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
    }
    func stop() { listener.cancel() }
}
