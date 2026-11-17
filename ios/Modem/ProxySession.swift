import Foundation
import Network

/// One client connection from the PC. Speaks SOCKS5 (CONNECT) and HTTP proxy
/// (CONNECT tunnels and plain http:// requests). Every outbound connection is
/// pinned to the cellular interface, so traffic never leaves over Wi-Fi.
final class ProxySession {
    var onClose: (() -> Void)?

    private let client: NWConnection
    private let queue: DispatchQueue
    private let stats: ProxyStats
    private let log: (String) -> Void

    private var upstream: NWConnection?
    private var buffer: [UInt8] = []
    private var closed = false
    private var uploadFinished = false
    private var downloadFinished = false
    private var requestReceived = false
    private var clientEOF = false
    private var lastActivity = DispatchTime.now()
    private var idleWatchdogArmed = false

    private static let chunkSize = 64 * 1024
    private static let maxHeaderSize = 64 * 1024
    private static let connectTimeout = 30
    private static let handshakeTimeout = 30
    private static let halfOpenIdleTimeout: UInt64 = 60

    init(client: NWConnection, queue: DispatchQueue, stats: ProxyStats, log: @escaping (String) -> Void) {
        self.client = client
        self.queue = queue
        self.stats = stats
        self.log = log
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        client.start(queue: queue)
        // Drop clients that never finish sending a request.
        queue.asyncAfter(deadline: .now() + .seconds(Self.handshakeTimeout)) { [weak self] in
            guard let self = self, !self.closed, !self.requestReceived else { return }
            self.close()
        }
        need(1) { [weak self] in self?.detectProtocol() }
    }

    func cancel() {
        close()
    }

    // MARK: - Reading from the client

    /// Runs `next` once at least `count` bytes from the client are buffered.
    private func need(_ count: Int, then next: @escaping () -> Void) {
        if buffer.count >= count {
            next()
            return
        }
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
            }
            if isComplete {
                self.clientEOF = true // remembered so the relay can pass the close on
            }
            if self.buffer.count >= count {
                next()
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.need(count, then: next)
            }
        }
    }

    private func detectProtocol() {
        switch buffer[0] {
        case 0x05: readSocksGreeting()
        case 0x04: close() // SOCKS4 is not supported
        default: readHTTPHeader()
        }
    }

    // MARK: - SOCKS5

    private func readSocksGreeting() {
        need(2) { [weak self] in
            guard let self = self else { return }
            let methodCount = Int(self.buffer[1])
            self.need(2 + methodCount) { [weak self] in
                guard let self = self else { return }
                let methods = Array(self.buffer[2..<(2 + methodCount)])
                self.buffer.removeFirst(2 + methodCount)
                guard methods.contains(0x00) else {
                    // Only "no authentication" is offered; the port is reachable from USB only.
                    self.reply([0x05, 0xFF], thenClose: true)
                    return
                }
                self.reply([0x05, 0x00])
                self.readSocksRequest()
            }
        }
    }

    private func readSocksRequest() {
        need(5) { [weak self] in
            guard let self = self else { return }
            guard self.buffer[0] == 0x05 else {
                self.close()
                return
            }
            let command = self.buffer[1]
            let addressType = self.buffer[3]
            let total: Int
            switch addressType {
            case 0x01: total = 4 + 4 + 2
            case 0x04: total = 4 + 16 + 2
            case 0x03: total = 4 + 1 + Int(self.buffer[4]) + 2
            default:
                self.socksFail(0x08)
                return
            }
            self.need(total) { [weak self] in
                guard let self = self else { return }
                let request = Array(self.buffer[0..<total])
                self.buffer.removeFirst(total)

                let host: NWEndpoint.Host
                switch addressType {
                case 0x01:
                    guard let address = IPv4Address(Data(request[4..<8])) else {
                        self.socksFail(0x01)
                        return
                    }
                    host = .ipv4(address)
                case 0x04:
                    guard let address = IPv6Address(Data(request[4..<20])) else {
                        self.socksFail(0x01)
                        return
                    }
                    host = .ipv6(address)
                default:
                    let length = Int(request[4])
                    host = NWEndpoint.Host(String(decoding: request[5..<(5 + length)], as: UTF8.self))
                }
                let portValue = UInt16(request[total - 2]) << 8 | UInt16(request[total - 1])

                guard command == 0x01 else {
                    // Only CONNECT. UDP can't travel over the USB link anyway.
                    self.socksFail(0x07)
                    return
                }
                guard portValue != 0, let port = NWEndpoint.Port(rawValue: portValue) else {
                    self.socksFail(0x01)
                    return
                }
                self.connectUpstream(host: host, port: port) { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        self.log("Could not reach \(host):\(portValue): \(error)")
                        self.socksFail(Self.socksCode(for: error))
                    } else {
                        self.reply([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                        self.startRelay()
                    }
                }
            }
        }
    }

    private func socksFail(_ code: UInt8) {
        reply([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0], thenClose: true)
    }

    private static func socksCode(for error: NWError) -> UInt8 {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return 0x05
            case .ENETUNREACH, .ENETDOWN: return 0x03
            case .EHOSTUNREACH, .EHOSTDOWN, .ETIMEDOUT: return 0x04
            default: return 0x01
            }
        case .dns:
            return 0x04
        default:
            return 0x01
        }
    }

    // MARK: - HTTP proxy

    private func readHTTPHeader() {
        if let end = Self.headerEnd(in: buffer) {
            let header = String(decoding: buffer[0..<end], as: UTF8.self)
            buffer.removeFirst(end)
            handleHTTPRequest(header)
            return
        }
        guard buffer.count < Self.maxHeaderSize else {
            httpError(431, "Request Header Fields Too Large", "Request header too large.")
            return
        }
        need(buffer.count + 1) { [weak self] in self?.readHTTPHeader() }
    }

    private static func headerEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i + 4
        }
        return nil
    }

    private func handleHTTPRequest(_ header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else {
            httpError(400, "Bad Request", "Malformed proxy request.")
            return
        }
        let method = parts[0]
        let target = parts[1]
        let version = parts[2]

        if method.uppercased() == "CONNECT" {
            guard let destination = Self.parseHostPort(target, defaultPort: 443) else {
                httpError(400, "Bad Request", "Bad CONNECT target.")
                return
            }
            connectUpstream(host: destination.host, port: destination.port) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.log("Could not reach \(target): \(error)")
                    self.httpError(502, "Bad Gateway", "Could not reach \(target) over cellular: \(error)")
                } else {
                    self.reply(Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                    self.startRelay()
                }
            }
            return
        }

        guard let absolute = Self.splitAbsoluteHTTP(target),
              let destination = Self.parseHostPort(absolute.authority, defaultPort: 80) else {
            httpError(400, "Bad Request", "Only http:// URLs and CONNECT are supported.")
            return
        }

        // Rewrite to an origin-form request and force one request per connection.
        var rewritten = "\(method) \(absolute.path) \(version)\r\n"
        var hasHost = false
        for line in lines.dropFirst() where !line.isEmpty {
            let lower = line.lowercased()
            if lower.hasPrefix("proxy-connection:") || lower.hasPrefix("proxy-authorization:")
                || lower.hasPrefix("connection:") || lower.hasPrefix("keep-alive:") {
                continue
            }
            if lower.hasPrefix("host:") { hasHost = true }
            rewritten += line + "\r\n"
        }
        if !hasHost {
            rewritten += "Host: \(absolute.authority)\r\n"
        }
        rewritten += "Connection: close\r\n\r\n"
        buffer = Array(rewritten.utf8) + buffer

        connectUpstream(host: destination.host, port: destination.port) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.log("Could not reach \(absolute.authority): \(error)")
                self.httpError(502, "Bad Gateway", "Could not reach \(absolute.authority) over cellular: \(error)")
            } else {
                self.startRelay()
            }
        }
    }

    /// Splits "http://host[:port]/path?query" by hand. URLComponents rejects
    /// characters such as | ^ { " that browsers send unencoded.
    private static func splitAbsoluteHTTP(_ target: String) -> (authority: String, path: String)? {
        let scheme = "http://"
        guard target.count > scheme.count, target.lowercased().hasPrefix(scheme) else { return nil }
        let rest = target.dropFirst(scheme.count)
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var authority = String(rest[..<end])
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...]) // drop user:password@
        }
        var path = String(rest[end...])
        if let hash = path.firstIndex(of: "#") {
            path = String(path[..<hash])
        }
        if path.isEmpty || path.hasPrefix("?") {
            path = "/" + path
        }
        guard !authority.isEmpty else { return nil }
        return (authority, path)
    }

    private static func parseHostPort(_ text: String, defaultPort: UInt16) -> (host: NWEndpoint.Host, port: NWEndpoint.Port)? {
        var hostPart = text
        var portValue = defaultPort
        if text.hasPrefix("[") {
            guard let closing = text.firstIndex(of: "]") else { return nil }
            hostPart = String(text[text.index(after: text.startIndex)..<closing])
            let rest = text[text.index(after: closing)...]
            if rest.hasPrefix(":") {
                guard let parsed = UInt16(rest.dropFirst()) else { return nil }
                portValue = parsed
            }
        } else if let colon = text.lastIndex(of: ":") {
            hostPart = String(text[..<colon])
            guard let parsed = UInt16(text[text.index(after: colon)...]) else { return nil }
            portValue = parsed
        }
        guard !hostPart.isEmpty, portValue != 0, let port = NWEndpoint.Port(rawValue: portValue) else { return nil }
        return (NWEndpoint.Host(hostPart), port)
    }

    private func httpError(_ code: Int, _ reason: String, _ message: String) {
        let body = message + "\n"
        let response = "HTTP/1.1 \(code) \(reason)\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + body
        reply(Array(response.utf8), thenClose: true)
    }

    // MARK: - Upstream over cellular

    private func connectUpstream(host: NWEndpoint.Host, port: NWEndpoint.Port, completion: @escaping (NWError?) -> Void) {
        requestReceived = true
        stats.requestStarted()

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.connectionTimeout = Self.connectTimeout

        let parameters = NWParameters(tls: nil, tcp: tcp)
        // The whole point of the app: only ever use the cellular radio.
        parameters.requiredInterfaceType = .cellular
        parameters.prohibitedInterfaceTypes = [.wifi, .wiredEthernet, .loopback]
        parameters.preferNoProxies = true

        let connection = NWConnection(host: host, port: port, using: parameters)
        upstream = connection

        var reported = false
        let report: (NWError?) -> Void = { error in
            guard !reported else { return }
            reported = true
            completion(error)
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.closed else { return }
            switch state {
            case .ready:
                report(nil)
            case .waiting(let error):
                // No viable cellular path, connection refused, DNS failure...
                report(error)
            case .failed(let error):
                if reported { self.close() } else { report(error) }
            case .cancelled:
                if reported { self.close() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(Self.connectTimeout + 5)) { [weak self] in
            guard let self = self, !self.closed else { return }
            report(.posix(.ETIMEDOUT))
        }
    }

    // MARK: - Relaying

    private func startRelay() {
        guard let upstream = upstream else {
            close()
            return
        }
        lastActivity = .now()
        let continueUpload: () -> Void = { [weak self] in
            guard let self = self, !self.closed else { return }
            if self.clientEOF {
                // The client already closed its side while sending the request.
                self.finish(upstream, upload: true)
            } else {
                self.pump(from: self.client, to: upstream, upload: true)
            }
        }
        if buffer.isEmpty {
            continueUpload()
        } else {
            let pending = Data(buffer)
            buffer.removeAll()
            stats.addUp(pending.count)
            upstream.send(content: pending, completion: .contentProcessed { [weak self] error in
                guard let self = self, !self.closed else { return }
                if error != nil {
                    self.close()
                } else {
                    continueUpload()
                }
            })
        }
        pump(from: upstream, to: client, upload: false)
    }

    private func pump(from source: NWConnection, to destination: NWConnection, upload: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let data = data, !data.isEmpty {
                self.lastActivity = .now()
                if upload { self.stats.addUp(data.count) } else { self.stats.addDown(data.count) }
                // Read the next chunk only after this one is handed off (flow control).
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self = self, !self.closed else { return }
                    if sendError != nil {
                        self.close()
                    } else if isComplete {
                        self.finish(destination, upload: upload)
                    } else if error != nil {
                        self.close()
                    } else {
                        self.pump(from: source, to: destination, upload: upload)
                    }
                })
            } else if isComplete {
                self.finish(destination, upload: upload)
            } else if error != nil {
                self.close()
            } else {
                self.pump(from: source, to: destination, upload: upload)
            }
        }
    }

    /// The source side closed its end: pass the close along, and tear the
    /// session down once both directions are finished.
    private func finish(_ destination: NWConnection, upload: Bool) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self = self, !self.closed else { return }
            if upload { self.uploadFinished = true } else { self.downloadFinished = true }
            if self.uploadFinished && self.downloadFinished {
                self.close()
            } else {
                self.watchHalfOpenConnection()
            }
        })
    }

    /// Once one side has closed, give up if nothing moves for a minute, so a
    /// peer that never closes its half can't hold the session (and a cellular
    /// socket) open forever.
    private func watchHalfOpenConnection() {
        guard !idleWatchdogArmed else { return }
        idleWatchdogArmed = true
        scheduleIdleCheck()
    }

    private func scheduleIdleCheck() {
        queue.asyncAfter(deadline: .now() + .seconds(15)) { [weak self] in
            guard let self = self, !self.closed else { return }
            let idleNanoseconds = DispatchTime.now().uptimeNanoseconds - self.lastActivity.uptimeNanoseconds
            if idleNanoseconds > Self.halfOpenIdleTimeout * 1_000_000_000 {
                self.close()
            } else {
                self.scheduleIdleCheck()
            }
        }
    }

    // MARK: - Helpers

    private func reply(_ bytes: [UInt8], thenClose: Bool = false) {
        let completion = NWConnection.SendCompletion.contentProcessed { [weak self] error in
            guard let self = self, !self.closed else { return }
            if error != nil || thenClose {
                self.close()
            }
        }
        if thenClose {
            client.send(content: Data(bytes), contentContext: .finalMessage, isComplete: true, completion: completion)
        } else {
            client.send(content: Data(bytes), completion: completion)
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
        upstream = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}
