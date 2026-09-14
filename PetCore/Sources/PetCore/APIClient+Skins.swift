//
//  APIClient+Skins.swift
//  PetCore
//

import Foundation

public extension APIClient {
    /// The skins the account was granted (the built-in skin isn't listed).
    func skins() async throws -> [SkinSummary] {
        try await send("GET", "skins")
    }

    /// A granted skin's zip. Throws a 404 server error when the account doesn't have it.
    func downloadSkin(id: String) async throws -> Data {
        guard (1...40).contains(id.count), id.allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }) else {
            throw APIError.server(status: 404, code: "SKIN_NOT_FOUND", message: "Skin not found")
        }
        return try await sendRaw("GET", "skins/\(id)/archive", body: nil, authorized: true)
    }

    /// Picks the account's skin on every device; nil picks the built-in one.
    func updateSkin(_ id: String?) async throws -> SyncSettings {
        try await send("PATCH", "me/settings", body: SkinPatch(skinId: id ?? ""))
    }
}

private nonisolated struct SkinPatch: Encodable {
    let skinId: String
}
