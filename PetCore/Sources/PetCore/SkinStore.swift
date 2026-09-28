//
//  SkinStore.swift
//  PetCore
//

import Foundation
import Observation
import os

public nonisolated enum SkinSelectionError: Error, Equatable {
    /// The pick was saved, but this device couldn't switch to it yet (download or install failed); it retries on
    /// the next sync.
    case notApplied
}

/// The account's skin on this device. It starts on the built-in pixel cat; `sync` follows the account's pick,
/// downloading a granted skin when needed, and falls back to the cat when the pick is gone (revoked).
@Observable
public final class SkinStore {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "skins")

    /// The skin to draw; nil only if even the built-in skin couldn't be unpacked (a full disk).
    public private(set) var current: InstalledSkin?
    /// Skins the account was granted, as of the last sync.
    public private(set) var granted: [SkinSummary] = []
    /// A pick getting dressed on this device's request: `current` switches to it once the friend's lines fit it.
    public private(set) var pending: PendingSkin?
    /// Called after `current` changes (the iPhone redraws its widget and Live Activity).
    @ObservationIgnored public var onChange: (() -> Void)?

    private let root: URL
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false

    public init(root: URL) {
        self.root = root
        let saved = SkinInstaller.current(in: root)
        if let saved, !saved.isBuiltIn || saved.sha256 == Self.builtInSHA256 {
            current = saved
        } else {
            current = Self.installBuiltIn(root: root) // first launch, or the app shipped a new cat
        }
    }

    /// Follows the account's pick. A call made while a sync runs waits for it and makes it do one more pass, so a
    /// change announced mid-sync is never missed. Failures keep the skin already shown.
    public func sync(api: APIClient) async {
        if let running {
            syncAgain = true
            return await running.value
        }
        let task = Task {
            repeat {
                syncAgain = false
                await refresh(api: api)
            } while syncAgain
            running = nil // same actor turn as the last check, so no request slips in between
        }
        running = task
        await task.value
    }

    /// Saves the pick for the whole account (nil = the built-in skin). Once the friend has lines, the request waits
    /// while they're rewritten for it (`pending` meanwhile) and throws if they couldn't be; the old skin stays.
    /// Throws `SkinSelectionError.notApplied` when the saved pick couldn't be applied here yet.
    public func select(_ id: String?, api: APIClient) async throws {
        pending = PendingSkin(skinId: id)
        defer { pending = nil }
        _ = try await api.updateSkin(id)
        await sync(api: api)
        guard current?.pickID == id else { throw SkinSelectionError.notApplied }
    }

    /// Back to the built-in skin, e.g. after signing out.
    public func reset() {
        granted = []
        pending = nil
        use(Self.installBuiltIn(root: root))
    }

    private func refresh(api: APIClient) async {
        do {
            let settings = try await api.syncSettings()
            let pick = settings.skinId
            granted = try await api.skins()
            guard let pick, let summary = granted.first(where: { $0.id == pick }) else {
                return use(Self.installBuiltIn(root: root))
            }
            if current?.id == summary.id, current?.sha256 == summary.sha256 { return }

            let archive = try await api.downloadSkin(id: summary.id)
            let root = self.root
            let installed = try await Task.detached {
                try SkinInstaller.install(archive: archive, expectedSHA256: summary.sha256, into: root)
            }.value
            use(installed)
        } catch APIError.signedOut {
            return
        } catch {
            Self.log.error("Skin sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func use(_ skin: InstalledSkin?) {
        guard let skin else { return }
        do {
            try SkinInstaller.setCurrent(skin, in: root)
        } catch {
            Self.log.error("Saving the current skin failed: \(error.localizedDescription, privacy: .public)")
        }
        guard skin != current else { return }
        current = skin
        onChange?()
    }

    // MARK: Built-in skin

    static let builtInArchive: Data? = Bundle.module
        .url(forResource: InstalledSkin.builtInID, withExtension: "zip")
        .flatMap { try? Data(contentsOf: $0) }

    private static let builtInSHA256 = builtInArchive.map(SkinInstaller.sha256(of:))

    static func installBuiltIn(root: URL) -> InstalledSkin? {
        guard let builtInArchive else {
            log.fault("pixel-cat.zip is missing from PetCore's resources")
            return nil
        }
        do {
            return try SkinInstaller.install(archive: builtInArchive, expectedSHA256: nil, into: root)
        } catch {
            log.fault("Unpacking the built-in skin failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
