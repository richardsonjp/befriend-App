//
//  MacConfig.swift
//  befriend
//

import Foundation
import PetCore

/// Build settings from Info.plist (see Config/Base.xcconfig) and the app's own files.
enum MacConfig {
    static var apiBaseURL: URL {
        URL(string: string("APIBaseURL")) ?? URL(string: "http://localhost:8305")!
    }

    static var staticAPIKey: String { string("StaticAPIKey") }

    static var googleClientID: String { string("GIDClientID") }

    static func makeAPIClient() -> APIClient {
        APIClient(baseURL: apiBaseURL, staticAPIKey: staticAPIKey, tokens: KeychainTokenStorage())
    }

    static var device: DeviceInfo {
        DeviceInfo(platform: "macos", name: Host.current().localizedName ?? "Mac")
    }

    private static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "befriend", directoryHint: .isDirectory)
    }

    static var triggerQueueURL: URL { supportDirectory.appending(path: "trigger-queue.json") }

    /// The last friend profile, so the pet appears offline too.
    static func loadFriend() -> FriendProfile? {
        guard let data = try? Data(contentsOf: supportDirectory.appending(path: "friend.json")) else { return nil }
        return try? Wire.decoder.decode(FriendProfile.self, from: data)
    }

    static func saveFriend(_ friend: FriendProfile?) {
        let url = supportDirectory.appending(path: "friend.json")
        guard let friend, let data = try? Wire.encoder.encode(friend) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The last sync settings from the server, applied before tracking starts on the next launch.
    static func loadSettings() -> SyncSettings? {
        guard let data = try? Data(contentsOf: supportDirectory.appending(path: "settings.json")) else { return nil }
        return try? Wire.decoder.decode(SyncSettings.self, from: data)
    }

    static func saveSettings(_ settings: SyncSettings?) {
        let url = supportDirectory.appending(path: "settings.json")
        guard let settings, let data = try? Wire.encoder.encode(settings) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func string(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}
