//
//  SyncModels.swift
//  PetCore
//
//  Pairing, trigger log and sync settings (M3).
//

import Foundation

public nonisolated struct PairingStart: Decodable, Equatable, Sendable {
    public let code: String
    /// Stays on the Mac: proves the claim comes from the Mac that showed the code.
    public let pollSecret: String
    public let expiresAt: Date

    /// What the QR encodes; the iPhone's Camera opens it in the app.
    public var url: URL { URL(string: "befriend://pair?code=\(code)")! }
}

public nonisolated struct PairingInfo: Decodable, Equatable, Sendable {
    public let deviceName: String
    public let expiresAt: Date
}

public nonisolated enum PairingClaim: Equatable, Sendable {
    /// The iPhone hasn't confirmed yet; poll again.
    case pending
    /// The session is stored; the Mac is signed in.
    case signedIn
}

public nonisolated struct SyncSettings: Codable, Equatable, Sendable {
    public var logSyncPaused: Bool
    public var excludedApps: [String]
    /// The account's skin; nil is the built-in one.
    public var skinId: String?

    public init(logSyncPaused: Bool = false, excludedApps: [String] = [], skinId: String? = nil) {
        self.logSyncPaused = logSyncPaused
        self.excludedApps = excludedApps
        self.skinId = skinId
    }

    public func excludes(appName: String) -> Bool {
        excludedApps.contains { $0.caseInsensitiveCompare(appName) == .orderedSame }
    }
}

/// One entry of the synced activity log.
public nonisolated struct TriggerEventRecord: Codable, Equatable, Sendable {
    public let clientEventId: UUID
    public let kind: TriggerKind
    public let appName: String?
    public let seconds: Int?
    public let occurredAt: Date

    public init(trigger: Trigger, at date: Date, id: UUID = UUID()) {
        clientEventId = id
        kind = trigger.kind
        // Whole seconds: that's what the wire format keeps, so a queued event reads back unchanged.
        occurredAt = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        switch trigger.sanitized {
        case .appSwitched(let name):
            appName = name
            seconds = nil
        case .wentIdle(let away), .returned(let away):
            appName = nil
            seconds = Int(away.rounded())
        case .leftApp, .poked, .checkIn:
            appName = nil
            seconds = nil
        }
    }
}
