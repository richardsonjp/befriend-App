//
//  APIClient+Sync.swift
//  PetCore
//

import Foundation

public extension APIClient {
    // MARK: Pairing (Mac side, signed out)

    func startPairing(deviceName: String) async throws -> PairingStart {
        try await send("POST", "auth/pairing", body: PairingStartBody(deviceName: deviceName), authorized: false)
    }

    /// One poll: `.pending` until the iPhone confirms, then `.signedIn` once (the session is saved). A code that
    /// expired or was used throws `APIError.server(status: 410, …)`.
    func claimPairing(code: String, pollSecret: String) async throws -> PairingClaim {
        let result: ClaimBody = try await send("POST", "auth/pairing/claim", body: ClaimRequest(code: code, pollSecret: pollSecret), authorized: false)
        guard let accessToken = result.accessToken, let refreshToken = result.refreshToken, let deviceId = result.deviceId else {
            return .pending
        }
        storeSession(AuthTokens(accessToken: accessToken, refreshToken: refreshToken, deviceId: deviceId))
        return .signedIn
    }

    // MARK: Pairing (iPhone side, signed in)

    /// Nil when the code is unknown, expired or already used.
    func pairingInfo(code: String) async throws -> PairingInfo? {
        guard let path = Self.pairingPath(code) else { return nil }
        do {
            return try await send("GET", path) as PairingInfo
        } catch APIError.server(status: 404, _, _) {
            return nil
        }
    }

    func confirmPairing(code: String) async throws {
        guard let path = Self.pairingPath(code) else { throw APIError.server(status: 404, code: "DATA_NOT_FOUND", message: "Data not found") }
        try await sendIgnoringData("POST", path + "/confirm")
    }

    // MARK: Activity

    /// Returns how many events were newly stored.
    func uploadTriggerEvents(_ events: [TriggerEventRecord]) async throws -> Int {
        let result: UploadResult = try await send("POST", "trigger-events", body: UploadBody(events: events))
        return result.accepted
    }

    func deleteTriggerEvents() async throws {
        try await sendIgnoringData("DELETE", "trigger-events")
    }

    func syncSettings() async throws -> SyncSettings {
        try await send("GET", "me/settings")
    }

    func updateSyncSettings(paused: Bool? = nil, excludedApps: [String]? = nil) async throws -> SyncSettings {
        try await send("PATCH", "me/settings", body: SettingsPatch(logSyncPaused: paused, excludedApps: excludedApps))
    }

    /// Codes are 8 letters/digits; anything else never reaches the URL.
    private static func pairingPath(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard (1...16).contains(trimmed.count), trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return "pairing/" + trimmed
    }
}

private nonisolated struct PairingStartBody: Encodable { let deviceName: String }
private nonisolated struct ClaimRequest: Encodable { let code: String; let pollSecret: String }
private nonisolated struct ClaimBody: Decodable {
    let status: String?
    let accessToken: String?
    let refreshToken: String?
    let deviceId: String?
}
private nonisolated struct UploadBody: Encodable { let events: [TriggerEventRecord] }
private nonisolated struct UploadResult: Decodable { let accepted: Int }

/// Only the fields present are changed (nil keys are left out of the JSON).
private nonisolated struct SettingsPatch: Encodable {
    let logSyncPaused: Bool?
    let excludedApps: [String]?

    enum CodingKeys: String, CodingKey { case logSyncPaused, excludedApps }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(logSyncPaused, forKey: .logSyncPaused)
        try container.encodeIfPresent(excludedApps, forKey: .excludedApps)
    }
}
