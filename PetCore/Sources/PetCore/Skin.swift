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
    public let format: Int
    public let id: String
    public let name: String
    public let vocabularyVersion: Int
    /// Body stills are size×size pixels, Dynamic Island heads miniSize×miniSize.
    public let size: Int
    public let miniSize: Int
    public let fps: Int
}

/// A skin unpacked on disk: skin.json (Lottie, one marker per action), stills/<action>/<mood>.png, mini/<mood>.png.
public nonisolated struct InstalledSkin: Equatable, Sendable {
    public static let builtInID = "pixel-cat"

    public let manifest: SkinManifest
    public let sha256: String
    public let folder: URL

    public var id: String { manifest.id }
    public var isBuiltIn: Bool { id == Self.builtInID }
    /// The account setting that selects this skin (`skin_id`): nil for the built-in one.
    public var pickID: String? { isBuiltIn ? nil : id }
    public var lottieURL: URL { folder.appending(path: "skin.json") }

    public func still(_ action: PetAction, _ mood: PetMood) -> URL {
        folder.appending(path: "stills/\(action.rawValue)/\(mood.rawValue).png")
    }

    /// The small head for the Dynamic Island and accessory widgets.
    public func mini(_ mood: PetMood) -> URL {
        folder.appending(path: "mini/\(mood.rawValue).png")
    }

    /// The Lottie layer an app shows for a mood (every face is its own layer; the rest are hidden).
    public static func faceLayer(_ mood: PetMood) -> String {
        "face_\(mood.rawValue)"
    }
}
