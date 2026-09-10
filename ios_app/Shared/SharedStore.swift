//
//  SharedStore.swift
//  befriend (app + widget)
//

import Foundation
import os
import PetCore

/// Files the app writes and the widget reads, in the App Group container.
nonisolated enum SharedStore {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "shared-store")
    private static let friendFile = "friend.json"
    private static let surfaceFile = "surface.json"

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroup)
    }

    static func loadFriend() -> FriendProfile? {
        guard let data = read(friendFile) else { return nil }
        return try? Wire.decoder.decode(FriendProfile.self, from: data)
    }

    static func saveFriend(_ friend: FriendProfile?) {
        write(friend.flatMap { try? Wire.encoder.encode($0) }, to: friendFile)
    }

    /// Surface state uses its own key names (it doubles as the Live Activity content state), so plain JSON coders.
    static func loadSurface() -> FriendSurfaceState? {
        guard let data = read(surfaceFile) else { return nil }
        return try? JSONDecoder().decode(FriendSurfaceState.self, from: data)
    }

    static func saveSurface(_ state: FriendSurfaceState?) {
        write(state.flatMap { try? JSONEncoder().encode($0) }, to: surfaceFile)
    }

    private static func read(_ name: String) -> Data? {
        guard let url = container?.appending(path: name) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Nil data deletes the file.
    private static func write(_ data: Data?, to name: String) {
        guard let url = container?.appending(path: name) else { return }
        do {
            if let data {
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            log.error("Writing \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
