//
//  CatchLink.swift
//  PetCore
//
//  Catch's fast lane (M41): tilt also goes as tiny UDP packets through the Wi-Fi router. Multipeer may ride
//  peer-to-peer Wi-Fi, which hops channels and stalls now and then; the router path doesn't. The Mac tells the phone
//  where to send (and a random key) over the encrypted Multipeer session; Multipeer stays the fallback.
//

import Foundation
import Network

public nonisolated struct CatchLink: Codable, Equatable, Sendable {
    public let hosts: [String]
    public let port: UInt16
    public let key: Data

    /// The key, the steer as a big-endian Double, then 1 while jump is held.
    static func packet(_ steer: Double, jump: Bool, key: Data) -> Data {
        withUnsafeBytes(of: steer.bitPattern.bigEndian) { key + Data($0) } + [jump ? 1 : 0]
    }

    /// The input from a packet sent with this key; anything else (another sender, junk, NaN) is nil.
    static func input(from packet: Data, key: Data) -> (steer: Double, jump: Bool)? {
        guard packet.count == key.count + 9, packet.prefix(key.count) == key else { return nil }
        let bytes = Array(packet.suffix(9))
        let value = Double(bitPattern: bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        return value.isFinite ? (max(-1, min(1, value)), bytes[8] == 1) : nil
    }

    /// This Mac's IPv4 addresses on Wi-Fi and Ethernet (`en*`), where the phone can reach it through the router.
    static func localAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { pointer in
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: entry.ifa_name).hasPrefix("en") else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            let text = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            return text.hasPrefix("169.254.") ? nil : text // no DHCP: not reachable through a router
        }
    }
}

/// The Mac's end: a UDP port open while a game runs.
public final class CatchLinkListener {
    /// Input from the phone, on the main actor.
    public var onInput: (_ steer: Double, _ jump: Bool) -> Void = { _, _ in }
    public private(set) var link: CatchLink?

    // ponytail: the key keeps other devices on the Wi-Fi from steering; it isn't secret from the account's own peers.
    private let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    public init() {}

    /// `ready` gets where to send once the port is open; nothing happens if it can't open (Multipeer still steers).
    public func start(ready: @escaping (CatchLink) -> Void) {
        guard listener == nil, let listener = try? NWListener(using: .udp) else { return }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, case .ready = state, let port = listener.port?.rawValue else { return }
                let link = CatchLink(hosts: CatchLink.localAddresses(), port: port, key: self.key)
                guard !link.hosts.isEmpty else { return }
                self.link = link
                ready(link)
            }
        }
        listener.start(queue: .main)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        link = nil
        connections.forEach { $0.cancel() }
        connections = []
    }

    private func accept(_ connection: NWConnection) {
        // One per phone socket, and the phone opens new ones on every reconnect: keep the newest few.
        if connections.count >= 4 { connections.removeFirst().cancel() }
        connections.append(connection)
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, error == nil else { return connection.cancel() }
                if let data, let input = CatchLink.input(from: data, key: self.key) { self.onInput(input.steer, input.jump) }
                self.receive(on: connection)
            }
        }
    }
}

/// The phone's end: sends each input to every address the Mac gave.
public final class CatchLinkSender {
    private var connections: [NWConnection] = []
    private var key = Data()
    private var current: CatchLink?

    public init() {}

    /// The Mac re-sends its link on every reconnect; the same one keeps the open sockets.
    public func connect(_ link: CatchLink) {
        guard link != current else { return }
        stop()
        current = link
        guard let port = NWEndpoint.Port(rawValue: link.port) else { return }
        key = link.key
        connections = link.hosts.prefix(4).map { host in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
            connection.start(queue: .main)
            return connection
        }
    }

    public func send(steer: Double, jump: Bool) {
        guard !connections.isEmpty else { return }
        let packet = CatchLink.packet(steer, jump: jump, key: key)
        connections.forEach { $0.send(content: packet, completion: .idempotent) }
    }

    public func stop() {
        connections.forEach { $0.cancel() }
        connections = []
        current = nil
    }
}
