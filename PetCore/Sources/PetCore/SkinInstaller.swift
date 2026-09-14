//
//  SkinInstaller.swift
//  PetCore
//

import CryptoKit
import Foundation
import ZIPFoundation

public nonisolated enum SkinInstallError: Error, Equatable {
    case checksumMismatch
    /// The zip, or what it unpacks to, is over the size limit.
    case tooLarge
    /// A file a skin doesn't have (or a duplicate); nothing outside the allowlist is ever written.
    case unexpectedEntry(String)
    case missingFile(String)
    case invalidManifest
    /// skin.json lacks a marker for this vocabulary action or motion.
    case missingMarker(String)
    /// skin.json lacks the face layer for this mood.
    case missingFaceLayer(String)
}

/// Unpacks and finds skins under a root folder: one `<id>@<sha256>` folder per installed skin, plus `current.json`
/// naming the skin to draw (widgets read it without talking to the backend).
public nonisolated enum SkinInstaller {
    static let maxArchiveBytes = 2 << 20 // the backend's skinpack.MaxZipBytes
    static let maxUnpackedBytes = 16 << 20
    static let format = 1
    private static let pointerFile = "current.json"

    /// Every file of a valid skin.
    static let expectedEntries: Set<String> = {
        var names: Set<String> = ["manifest.json", "skin.json"]
        for mood in PetMood.allCases {
            names.insert("mini/\(mood.rawValue).png")
            for action in PetAction.allCases {
                names.insert("stills/\(action.rawValue)/\(mood.rawValue).png")
            }
        }
        return names
    }()

    /// Checks a skin zip and unpacks it into `root/<id>@<sha256>`, or returns that folder when it's already there.
    /// It's staged in a temporary folder and moved into place only once complete.
    public static func install(archive data: Data, expectedSHA256: String?, into root: URL) throws -> InstalledSkin {
        guard data.count <= maxArchiveBytes else { throw SkinInstallError.tooLarge }
        let sha = sha256(of: data)
        if let expectedSHA256, expectedSHA256.lowercased() != sha { throw SkinInstallError.checksumMismatch }

        let archive = try Archive(data: data, accessMode: .read)
        let entries = Array(archive)
        try checkEntries(entries)
        let manifest = try readManifest(archive, entries)

        let fileManager = FileManager.default
        let folder = root.appending(path: "\(manifest.id)@\(sha)", directoryHint: .isDirectory)
        if let existing = load(folder: folder) { return existing }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        try unpack(archive, entries, into: staging)
        try checkAnimation(staging.appending(path: "skin.json"))

        do {
            try fileManager.moveItem(at: staging, to: folder)
        } catch {
            // Another process (the app or its widget) installed the same skin first.
            if let existing = load(folder: folder) { return existing }
            throw error
        }
        return InstalledSkin(manifest: manifest, sha256: sha, folder: folder)
    }

    /// The skin to draw, as last chosen on this device.
    public static func current(in root: URL) -> InstalledSkin? {
        guard let data = try? Data(contentsOf: root.appending(path: pointerFile)),
              let pointer = try? JSONDecoder().decode(Pointer.self, from: data),
              isFolderName(pointer.folder) else { return nil }
        return load(folder: root.appending(path: pointer.folder, directoryHint: .isDirectory))
    }

    /// Makes `skin` the one to draw and deletes every other installed skin (older versions, revoked skins).
    /// ponytail: the app and its widget can race here; a pointer left at a pruned folder reads as no skin (the
    /// built-in one or a symbol shows) until the next sync.
    public static func setCurrent(_ skin: InstalledSkin, in root: URL) throws {
        let pointer = try JSONEncoder().encode(Pointer(folder: skin.folder.lastPathComponent))
        try pointer.write(to: root.appending(path: pointerFile), options: .atomic)

        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where isFolderName(name) && name != skin.folder.lastPathComponent {
            try? FileManager.default.removeItem(at: root.appending(path: name, directoryHint: .isDirectory))
        }
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func load(folder: URL) -> InstalledSkin? {
        let name = folder.lastPathComponent
        guard let at = name.lastIndex(of: "@"),
              let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let manifest = try? Wire.decoder.decode(SkinManifest.self, from: data) else { return nil }
        return InstalledSkin(manifest: manifest, sha256: String(name[name.index(after: at)...]), folder: folder)
    }

    private static func checkEntries(_ entries: [Entry]) throws {
        var seen: Set<String> = []
        for entry in entries {
            guard entry.type == .file, expectedEntries.contains(entry.path), seen.insert(entry.path).inserted else {
                throw SkinInstallError.unexpectedEntry(entry.path)
            }
        }
        if let missing = expectedEntries.subtracting(seen).sorted().first {
            throw SkinInstallError.missingFile(missing)
        }
    }

    /// Writes the entries, counting the bytes actually inflated: sizes in the zip's headers could lie.
    private static func unpack(_ archive: Archive, _ entries: [Entry], into staging: URL) throws {
        var unpacked = 0
        for entry in entries {
            var content = Data()
            try archive.extract(entry) { chunk in
                unpacked += chunk.count
                guard unpacked <= maxUnpackedBytes else { throw SkinInstallError.tooLarge }
                content.append(chunk)
            }
            let url = staging.appending(path: entry.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url)
        }
    }

    private static func readManifest(_ archive: Archive, _ entries: [Entry]) throws -> SkinManifest {
        guard let entry = entries.first(where: { $0.path == "manifest.json" }) else { throw SkinInstallError.missingFile("manifest.json") }
        var data = Data()
        try archive.extract(entry) { chunk in
            data.append(chunk)
            guard data.count <= 64 << 10 else { throw SkinInstallError.invalidManifest }
        }
        guard let manifest = try? Wire.decoder.decode(SkinManifest.self, from: data),
              manifest.format == format,
              manifest.vocabularyVersion == Vocabulary.version,
              isSkinID(manifest.id) else { throw SkinInstallError.invalidManifest }
        return manifest
    }

    /// The animation must play every action and motion, and show every mood.
    private static func checkAnimation(_ lottie: URL) throws {
        let animation = try JSONDecoder().decode(Animation.self, from: Data(contentsOf: lottie))
        let markers = Set(animation.markers.map(\.cm))
        let required = PetAction.allCases.map(\.rawValue) + [InstalledSkin.walkMarker]
        if let missing = required.first(where: { !markers.contains($0) }) {
            throw SkinInstallError.missingMarker(missing)
        }
        let layers = Set(animation.layers.compactMap(\.nm))
        if let missing = PetMood.allCases.first(where: { !layers.contains(InstalledSkin.faceLayer($0)) }) {
            throw SkinInstallError.missingFaceLayer(missing.rawValue)
        }
    }

    private static func isSkinID(_ id: String) -> Bool {
        (1...40).contains(id.count) && id.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }

    /// `<id>@<sha256>`: never a path, and never the staging folders.
    private static func isFolderName(_ name: String) -> Bool {
        guard let at = name.firstIndex(of: "@") else { return false }
        let sha = name[name.index(after: at)...]
        return isSkinID(String(name[..<at])) && sha.count == 64 && sha.allSatisfy(\.isHexDigit)
    }

    private struct Pointer: Codable {
        let folder: String
    }

    private struct Animation: Decodable {
        struct Marker: Decodable { let cm: String }
        struct Layer: Decodable { let nm: String? }
        let markers: [Marker]
        let layers: [Layer]
    }
}
