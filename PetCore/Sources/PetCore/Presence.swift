//
//  Presence.swift
//  PetCore
//
//  Which device holds the friend (M4): the backend decides, the Mac reports over a WebSocket, the iPhone claims
//  and releases, and on the same Wi-Fi the iPhone also tells the Mac directly.
//

import CryptoKit
import Foundation
import MultipeerConnectivity
import os

public nonisolated enum PresenceOwner: String, Codable, Sendable {
    case phone
    case mac
}

public nonisolated struct PresenceState: Decodable, Equatable, Sendable {
    public let owner: PresenceOwner
    public let changedAt: Date
}

public extension APIClient {
    func presence() async throws -> PresenceState {
        try await send("GET", "presence")
    }

    /// The iPhone app is in the foreground; renew every minute (a claim lasts 5).
    func claimPresence() async throws -> PresenceState {
        try await send("POST", "presence/claim")
    }

    func releasePresence() async throws -> PresenceState {
        try await send("POST", "presence/release")
    }

    /// A signed request for the Mac's presence WebSocket. Makes one authorized call first so an expired access
    /// token is refreshed before the socket uses it.
    func presenceSocketRequest() async throws -> URLRequest {
        _ = try await presence()
        guard let session = tokens.load() else { throw APIError.signedOut }
        var components = URLComponents(url: baseURL.appending(path: "api/presence/ws"), resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        guard let url = components?.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue(staticAPIKey, forHTTPHeaderField: "STATIC-API-KEY")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// The same-Wi-Fi fast path: the iPhone announces claim/release and the Mac reacts before the backend round trip.
/// Peers only connect to devices of the same account (a hash of the user ID travels in discovery), and sessions
/// are encrypted.
// ponytail: the account tag keeps strangers' devices apart, it isn't authentication; a spoofed message can only
// hide or show a friend until the backend's answer arrives.
public final class PresencePeer: NSObject {
    public enum Message: String, Codable, Sendable {
        case claim
        case release
    }

    nonisolated static let serviceType = "befriend-pres"
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "presence-peer")

    /// Messages from the other device, on the main actor.
    public var onMessage: (Message) -> Void = { _ in }
    public var onCatch: (CatchMessage) -> Void = { _ in }
    /// The other device joined or left, on the main actor.
    public var onConnectedChange: (Bool) -> Void = { _ in }
    public private(set) var isConnected = false

    private let peerID: MCPeerID
    private let accountTag: String
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    public init(userID: String, displayName: String) {
        peerID = MCPeerID(displayName: String(displayName.prefix(60)))
        accountTag = Self.accountTag(for: userID)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["account": accountTag], serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    nonisolated static func accountTag(for userID: String) -> String {
        SHA256.hash(data: Data(userID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    public func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    public func send(_ message: Message) {
        guard !session.connectedPeers.isEmpty, let data = try? JSONEncoder().encode(message) else { return }
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            Self.log.error("Sending \(message.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The Mac games (M41, M42) over the same session: input is sent unreliably (a late one is useless, the next is 16 ms away).
    public func send(_ message: CatchMessage) {
        guard !session.connectedPeers.isEmpty, let data = try? JSONEncoder().encode(message) else { return }
        let mode: MCSessionSendDataMode = if case .input = message { .unreliable } else { .reliable }
        do {
            try session.send(data, toPeers: session.connectedPeers, with: mode)
        } catch {
            Self.log.error("Sending a catch message failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deliver(_ data: Data) {
        if let message = try? JSONDecoder().decode(Message.self, from: data) {
            onMessage(message)
        } else if let message = try? JSONDecoder().decode(CatchMessage.self, from: data) {
            onCatch(message)
        }
    }
}

extension PresencePeer: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            let connected = !self.session.connectedPeers.isEmpty // read now, so quick flips can't land out of order
            guard connected != self.isConnected else { return }
            self.isConnected = connected
            self.onConnectedChange(connected)
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.deliver(data) }
    }

    nonisolated public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    nonisolated public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let tag = context.flatMap { String(data: $0, encoding: .utf8) }
        Task { @MainActor in
            invitationHandler(tag == self.accountTag, tag == self.accountTag ? self.session : nil)
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let tag = info?["account"]
        Task { @MainActor in
            // Only one side invites (the lower name), so two devices don't cross invitations.
            guard tag == self.accountTag, self.peerID.displayName < peerID.displayName || self.peerID.displayName == peerID.displayName else { return }
            browser.invitePeer(peerID, to: self.session, withContext: Data(self.accountTag.utf8), timeout: 10)
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
