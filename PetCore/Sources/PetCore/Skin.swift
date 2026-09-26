//
//  Skin.swift
//  PetCore
//
//  Character skins (M6): the built-in pixel cat, or a skin granted to the account and downloaded from the backend.
//

import Foundation

/// A granted skin as listed by `GET /skins`.
public nonisolated struct SkinSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let version: Int
    public let sha256: String
    /// Zip bytes.
    public let size: Int
}

/// manifest.json inside a skin zip (built by the backend's skinpack).
public nonisolated struct SkinManifest: Codable, Equatable, Sendable {
    /// One animation: "wave" plays in any mood, "wave/grumpy" only in that mood.
    public struct Clip: Codable, Equatable, Sendable {
        public let name: String
        public let frames: Int
    }

    public let format: Int
    public let id: String
    public let name: String
    /// Frames are size×size pixels, heads miniSize×miniSize.
    public let size: Int
    public let miniSize: Int
    public let fps: Int
    public let clips: [Clip]
    /// Moods the artist drew; others show the plain frames and mini/default.png.
    public let moods: [String]
}

/// A skin unpacked on disk: frames/<clip>/<n>.png and mini/<mood or default>.png.
public nonisolated struct InstalledSkin: Equatable, Sendable {
    public static let builtInID = "pixel-cat"
    /// The walk cycle: the Mac plays it while moving the friend; the AI never picks it.
    public static let walk = "walk"
    /// Every skin draws a plain idle, walk and jump.
    public static let required = ["idle", walk, "jump"]

    public let manifest: SkinManifest
    public let sha256: String
    public let folder: URL

    public var id: String { manifest.id }
    public var isBuiltIn: Bool { id == Self.builtInID }
    /// The account setting that selects this skin (`skin_id`): nil for the built-in one.
    public var pickID: String? { isBuiltIn ? nil : id }
    /// The clip to play: the action in this mood, else the plain action, else idle.
    public func clip(_ action: String, _ mood: String) -> SkinManifest.Clip {
        let clips = manifest.clips
        return clips.first { $0.name == "\(action)/\(mood)" }
            ?? clips.first { $0.name == action }
            ?? clips.first { $0.name == "idle" }
            ?? SkinManifest.Clip(name: "idle", frames: 1) // ponytail: the installer guarantees idle; never reached
    }

    public func frame(_ clip: SkinManifest.Clip, _ index: Int) -> URL {
        folder.appending(path: "frames/\(clip.name)/\(index).png")
    }

    /// Frame 0, drawn by widgets and Live Activities.
    public func still(_ action: PetAction, _ mood: PetMood) -> URL {
        frame(clip(action.rawValue, mood.rawValue), 0)
    }

    /// The small head for the Dynamic Island and accessory widgets.
    public func mini(_ mood: PetMood) -> URL {
        let name = manifest.moods.contains(mood.rawValue) ? mood.rawValue : "default"
        return folder.appending(path: "mini/\(name).png")
    }
}
