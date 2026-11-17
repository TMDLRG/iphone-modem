import Foundation
import Network

/// Makes IPv4 addresses reachable on IPv6-only cellular networks (common with
/// US carriers). There, a connection pinned to cellular cannot reach an IPv4
/// literal such as 1.1.1.1 ("network down"), but the carrier's NAT64 gateway
/// can, through a synthesized IPv6 address: the network's NAT64 prefix followed
/// by the IPv4 address (RFC 6052). The prefix is discovered per RFC 7050 by
/// resolving ipv4only.arpa over cellular.
///
/// Hostnames need none of this: the carrier's DNS64 already returns usable
/// IPv6 addresses for them. It matters for clients that only know IP
/// addresses, such as tun2socks in the PC's full mode.
final class Nat64 {
    static let shared = Nat64()

    /// 64:ff9b::/96, the well-known prefix, used until discovery succeeds.
    private static let wellKnownPrefix: [UInt8] = [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]

    private let queue = DispatchQueue(label: "modem.nat64")
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var probe: NWConnection?
    private var prefix: [UInt8]?
    private var synthesizeFirst = false

    /// True when IPv4 addresses should go straight to their NAT64 form.
    var preferSynthesis: Bool {
        lock.lock(); defer { lock.unlock() }
        return synthesizeFirst
    }

    func start() {
        queue.async {
            guard self.monitor == nil else { return }
            let monitor = NWPathMonitor(requiredInterfaceType: .cellular)
            monitor.pathUpdateHandler = { [weak self] path in
                self?.pathChanged(path)
            }
            monitor.start(queue: self.queue)
            self.monitor = monitor
        }
    }

    /// The IPv6 address that reaches `address` through the carrier's NAT64.
    func synthesize(_ address: IPv4Address) -> IPv6Address? {
        lock.lock()
        let base = prefix ?? Self.wellKnownPrefix
        lock.unlock()
        return IPv6Address(Data(base + [UInt8](address.rawValue)))
    }

    /// A synthesized address worked where the IPv4 one did not: use it directly from now on.
    func synthesisWorked() {
        lock.lock(); synthesizeFirst = true; lock.unlock()
    }

    private func pathChanged(_ path: NWPath) {
        let ipv6Only = path.status == .satisfied && path.supportsIPv6 && !path.supportsIPv4
        lock.lock()
        synthesizeFirst = ipv6Only
        prefix = nil
        lock.unlock()
        if path.status == .satisfied && path.supportsIPv6 {
            discoverPrefix()
        }
    }

    /// RFC 7050: on a NAT64 network, ipv4only.arpa resolves to prefix + 192.0.0.170/171.
    /// A UDP "connection" resolves the name without sending any packets.
    private func discoverPrefix() {
        probe?.cancel()
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .cellular
        let connection = NWConnection(host: "ipv4only.arpa", port: 9, using: parameters)
        probe = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint,
                   case let .ipv6(address) = host {
                    let bytes = [UInt8](address.rawValue)
                    if bytes.count == 16 {
                        let tail = Array(bytes[12..<16])
                        if tail == [192, 0, 0, 170] || tail == [192, 0, 0, 171] {
                            self.lock.lock()
                            self.prefix = Array(bytes[0..<12])
                            self.lock.unlock()
                        }
                    }
                }
                connection.cancel()
            case .failed, .waiting:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak connection] in
            connection?.cancel()
        }
    }
}
