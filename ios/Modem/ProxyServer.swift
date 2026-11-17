import Foundation
import Network

/// Traffic counters shared between the proxy queue and the UI.
final class ProxyStats {
    struct Snapshot: Equatable {
        var bytesUp: UInt64 = 0
        var bytesDown: UInt64 = 0
        var activeSessions = 0
        var totalRequests = 0
    }

    private let lock = NSLock()
    private var value = Snapshot()

    func addUp(_ count: Int) {
        lock.lock(); value.bytesUp &+= UInt64(count); lock.unlock()
    }

    func addDown(_ count: Int) {
        lock.lock(); value.bytesDown &+= UInt64(count); lock.unlock()
    }

    func sessionOpened() {
        lock.lock(); value.activeSessions += 1; lock.unlock()
    }

    func sessionClosed() {
        lock.lock(); value.activeSessions -= 1; lock.unlock()
    }

    func requestStarted() {
        lock.lock(); value.totalRequests += 1; lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Listens for proxy clients from the PC. Connections forwarded over USB by
/// Apple's usbmux arrive on the phone's loopback interface, so anything that
/// does not come from loopback (for example another device on Wi-Fi) is refused.
final class ProxyServer {
    enum State: Equatable {
        case starting
        case ready(port: UInt16, loopbackOnly: Bool)
        case failed(String)
    }

    /// Ports the app may listen on, in order. The PC bridge probes the same
    /// list, so if another app on the phone holds one, the next is used.
    /// (1080 is avoided on purpose: proxy and VPN apps commonly take it.)
    static let candidatePorts: [UInt16] = Array(41080...41089)

    let stats = ProxyStats()
    var onLog: ((String) -> Void)?
    var onState: ((State) -> Void)?

    private let queue = DispatchQueue(label: "modem.proxy")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ProxySession] = [:]
    private var stopped = false
    private var loopbackOnly = true
    private var portIndex = 0
    private var port: UInt16 { Self.candidatePorts[portIndex] }

    func start() {
        queue.async { self.startListener() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            let open = Array(self.sessions.values)
            self.sessions.removeAll()
            open.forEach { $0.cancel() }
        }
    }

    private func startListener() {
        guard !stopped, listener == nil else { return }
        onState?(.starting)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onState?(.failed("Invalid port \(port)"))
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if loopbackOnly {
            parameters.requiredInterfaceType = .loopback
        }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: nwPort)
        } catch {
            handleListenerFailure(error as? NWError, description: "\(error)")
            return
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self = self, let current = newListener, self.listener === current else { return }
            switch state {
            case .ready:
                self.log("Listening for the PC on port \(self.port)")
                self.onState?(.ready(port: self.port, loopbackOnly: self.loopbackOnly))
            case .failed(let error), .waiting(let error):
                self.handleListenerFailure(error, description: "\(error)")
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener = newListener
        newListener.start(queue: queue)
    }

    private func handleListenerFailure(_ error: NWError?, description message: String) {
        listener?.cancel()
        listener = nil
        guard !stopped else { return }
        if case .posix(.EADDRINUSE)? = error {
            // Another app on the phone (or our own previous listener that is
            // still shutting down) holds this port: move on to the next one.
            let busy = port
            portIndex = (portIndex + 1) % Self.candidatePorts.count
            log("Port \(busy) is in use on this iPhone; trying port \(port).")
            onState?(.failed("Port \(busy) is busy, trying \(port)"))
            let delay: TimeInterval = portIndex == 0 ? 3 : 0.2 // pause after trying them all
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.startListener()
            }
            return
        }
        if loopbackOnly {
            // Fall back to listening everywhere; accept() still rejects
            // anything that is not loopback, so Wi-Fi peers stay locked out.
            loopbackOnly = false
            log("Loopback-only listener failed (\(message)); retrying with a USB-only filter.")
            startListener()
        } else {
            onState?(.failed(message))
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.startListener()
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        guard Self.isLoopback(connection.endpoint) else {
            log("Refused a client that did not come over USB: \(connection.endpoint)")
            connection.cancel()
            return
        }
        let session = ProxySession(client: connection, queue: queue, stats: stats) { [weak self] message in
            self?.log(message)
        }
        let id = ObjectIdentifier(session)
        sessions[id] = session
        stats.sessionOpened()
        session.onClose = { [weak self] in
            guard let self = self else { return }
            self.sessions[id] = nil
            self.stats.sessionClosed()
        }
        session.start()
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            return address.isLoopback || (address.asIPv4?.isLoopback ?? false)
        case .name(let name, _):
            return name == "localhost" || name == "127.0.0.1" || name == "::1"
        @unknown default:
            return false
        }
    }
}
