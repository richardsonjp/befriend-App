//
//  AppConfig.swift
//  befriend (app + widget)
//

import Foundation
import PetCore

/// Build settings surfaced through Info.plist (see Config/Base.xcconfig).
nonisolated enum AppConfig {
    static let appGroup = "group.com.richardsonjp.befriend"

    static var apiBaseURL: URL {
        URL(string: string("APIBaseURL")) ?? URL(string: "http://localhost:8305")!
    }

    static var staticAPIKey: String { string("StaticAPIKey") }

    /// sandbox | production: which APNs environment this build's push tokens belong to.
    static var apnsEnvironment: String { string("APNSEnvironment") }

    /// The shared keychain group, or nil in unsigned builds (no team prefix), which then use the app's own keychain.
    static var keychainAccessGroup: String? {
        let group = string("KeychainAccessGroup")
        return group.isEmpty || group.hasPrefix("com.") ? nil : group
    }

    @MainActor
    static func makeAPIClient() -> APIClient {
        APIClient(baseURL: apiBaseURL, staticAPIKey: staticAPIKey, tokens: KeychainTokenStorage(accessGroup: keychainAccessGroup))
    }

    private static func string(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}

nonisolated extension Data {
    /// APNs tokens travel as lowercase hex.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
