//
//  PresenceReporter.swift
//  befriend
//

import AppKit
import Foundation
import os
import PetCore

/// Tells the backend whether this Mac's user is active, over the presence WebSocket, and hears who holds the friend.
/// Active means input within the last 2 minutes, the screen unlocked and the Mac awake.
final class PresenceReporter {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "presence")
    private static let idleLimit: TimeInterval = 120
    private static let heartbeatInterval: Duration = .seconds(30) // also keeps proxies (e.g. Cloudflare, 100 s) from closing it
    private static let maxBackoff: Duration = .seconds(30)

    /// Called whenever `isActive`, `owner` or `isConnected` changes.
    var onChange: () -> Void = {}
    /// Called when the backend says the account's skin changed (picked elsewhere, granted, revoked or updated).
    var onSkinChanged: () -> Void = {}

    private(set) var isActive = true
    private(set) var owner: PresenceOwner?
    private(set) var isConnected = false

    private let api: APIClient
    private var idleSeconds: TimeInterval = 0
    private var screenLocked = false
    private var asleep = false
    private var socket: URLSessionWebSocketTask?
    private var connection: Task<Void, Never>?
    private var backoff: Duration = .seconds(1)
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(api: APIClient) {
        self.api = api
    }

    func start() {
        guard connection == nil else { return }
        observeSystem()
        connection = Task { [weak self] in await self?.maintainConnection() }
    }

    func stop() {
        connection?.cancel()
        connection = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        isConnected = false
        owner = nil
    }

    /// Fed by TriggerMonitor's 2-second idle poll.
    func update(idleSeconds: TimeInterval) {
        self.idleSeconds = idleSeconds
        refreshActive()
    }

    private func refreshActive() {
        let active = idleSeconds < Self.idleLimit && !screenLocked && !asleep
        guard active != isActive else { return }
        isActive = active
        sendState()
        onChange()
    }

    // MARK: Socket

    private func maintainConnection() async {
        while !Task.isCancelled {
            do {
                let request = try await api.presenceSocketRequest()
                let socket = URLSession.shared.webSocketTask(with: request)
                self.socket = socket
                socket.resume()
                sendState()
                let heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: Self.heartbeatInterval)
                        self?.sendState()
                    }
                }
                defer { heartbeat.cancel() }
                try await receive(from: socket)
            } catch is CancellationError {
                return
            } catch APIError.signedOut {
                return
            } catch {
                Self.log.notice("Presence socket closed: \(error.localizedDescription, privacy: .public)")
            }

            socket = nil
            if isConnected {
                isConnected = false
                onChange()
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, Self.maxBackoff)
        }
    }

    private func receive(from socket: URLSessionWebSocketTask) async throws {
        while true {
            let message = try await socket.receive()
            guard case .string(let text) = message,
                  let decoded = try? JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8)) else { continue }
            backoff = .seconds(1)
            if decoded.skinChanged == true { onSkinChanged() }
            if let newOwner = decoded.owner, !isConnected || newOwner != owner {
                isConnected = true
                owner = newOwner
                onChange()
            }
        }
    }

    private func sendState() {
        socket?.send(.string(isActive ? #"{"active":true}"# : #"{"active":false}"#)) { _ in }
    }

    /// `{"owner": …}` on connect and on every owner change, `{"skin_changed": true}` when the skin changes; both can
    /// arrive in one message.
    private struct ServerMessage: Decodable {
        let owner: PresenceOwner?
        let skinChanged: Bool?

        enum CodingKeys: String, CodingKey {
            case owner
            case skinChanged = "skin_changed"
        }
    }

    // MARK: System state

    private func observeSystem() {
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.screenLocked = true }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.screenLocked = false }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name.rawValue) { $0.asleep = true }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name.rawValue) { $0.asleep = false }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ apply: @escaping (PresenceReporter) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                apply(self)
                self.refreshActive()
            }
        }
        observers.append((center, token))
    }
}
