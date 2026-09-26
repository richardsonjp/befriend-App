import Foundation
import Testing
import ZIPFoundation
@testable import PetCore

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "skins-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// Rewrites a zip's files, e.g. to break a valid skin in one way.
private func repack(_ data: Data, _ edit: (inout [String: Data]) throws -> Void) throws -> Data {
    let source = try Archive(data: data, accessMode: .read)
    var files: [String: Data] = [:]
    for entry in source {
        var content = Data()
        try source.extract(entry) { content.append($0) }
        files[entry.path] = content
    }
    try edit(&files)
    let out = try Archive(data: Data(), accessMode: .create)
    for (path, content) in files.sorted(by: { $0.key < $1.key }) {
        try out.addEntry(with: path, type: .file, uncompressedSize: Int64(content.count)) { position, size in
            content.subdata(in: Int(position)..<Int(position) + size)
        }
    }
    return try #require(out.data)
}

/// Changes top-level keys of a JSON object file.
private func editJSON(_ json: Data?, _ edit: (inout [String: Any]) -> Void) throws -> Data {
    let data = try #require(json)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    edit(&object)
    return try JSONSerialization.data(withJSONObject: object)
}

struct SkinInstallerTests {
    let root = temporaryRoot()

    @Test func installsTheBuiltInSkin() throws {
        let archive = try #require(SkinStore.builtInArchive)
        let skin = try SkinInstaller.install(archive: archive, expectedSHA256: nil, into: root)
        #expect(skin.id == InstalledSkin.builtInID && skin.isBuiltIn)
        #expect(skin.manifest.size == 32 && skin.manifest.miniSize == 16 && skin.manifest.format == 2)
        #expect(skin.folder.lastPathComponent == "pixel-cat@\(SkinInstaller.sha256(of: archive))")
        for action in PetAction.allCases {
            for mood in PetMood.allCases {
                #expect(FileManager.default.fileExists(atPath: skin.still(action, mood).path))
            }
        }
        #expect(FileManager.default.fileExists(atPath: skin.mini(.lonely).path))
        #expect(skin.clip("wave", "grumpy").name == "wave/grumpy")
        #expect(skin.clip("walk", "happy").name == "walk", "a mood the skin lacks plays the plain clip")
        #expect(skin.clip("moonwalk", "grumpy").name == "idle", "an action the skin lacks plays idle")

        let again = try SkinInstaller.install(archive: archive, expectedSHA256: SkinInstaller.sha256(of: archive).uppercased(), into: root)
        #expect(again == skin, "an installed skin is reused")
        #expect(SkinInstaller.current(in: root) == nil)
        try SkinInstaller.setCurrent(skin, in: root)
        #expect(SkinInstaller.current(in: root) == skin)
    }

    @Test func rejectsBadArchives() throws {
        let archive = try #require(SkinStore.builtInArchive)
        #expect(throws: SkinInstallError.checksumMismatch) {
            try SkinInstaller.install(archive: archive, expectedSHA256: String(repeating: "0", count: 64), into: root)
        }
        #expect(throws: SkinInstallError.tooLarge) {
            try SkinInstaller.install(archive: Data(count: SkinInstaller.maxArchiveBytes + 1), expectedSHA256: nil, into: root)
        }

        let cases: [(String, (inout [String: Data]) throws -> Void, SkinInstallError)] = [
            ("an extra file", { $0["notes.txt"] = Data("hi".utf8) }, .unexpectedEntry("notes.txt")),
            ("a path outside the skin", { $0["../escape.png"] = Data() }, .unexpectedEntry("../escape.png")),
            ("a missing frame", { $0["frames/wave/grumpy/0.png"] = nil }, .missingFile("frames/wave/grumpy/0.png")),
            ("an older format", { $0["manifest.json"] = try editJSON($0["manifest.json"]) { $0["format"] = 1 } }, .invalidManifest),
            ("an id that isn't a skin id", { $0["manifest.json"] = try editJSON($0["manifest.json"]) { $0["id"] = "../cat" } }, .invalidManifest),
            ("a clip that escapes the folder", {
                $0["manifest.json"] = try editJSON($0["manifest.json"]) { manifest in
                    manifest["clips"] = [["name": "idle", "frames": 1], ["name": "walk", "frames": 1], ["name": "jump", "frames": 1],
                                         ["name": "focus", "frames": 1], ["name": "../x", "frames": 1]]
                }
            }, .invalidManifest),
            ("no plain focus", {
                $0["manifest.json"] = try editJSON($0["manifest.json"]) { manifest in
                    manifest["clips"] = (manifest["clips"] as? [[String: Any]])?.filter { $0["name"] as? String != "focus" }
                }
            }, .invalidManifest),
            ("no plain walk", {
                $0["manifest.json"] = try editJSON($0["manifest.json"]) { manifest in
                    manifest["clips"] = (manifest["clips"] as? [[String: Any]])?.filter { $0["name"] as? String != "walk" }
                }
            }, .invalidManifest),
            ("more frames than files", {
                $0["manifest.json"] = try editJSON($0["manifest.json"]) { manifest in
                    manifest["clips"] = [["name": "idle", "frames": 9999], ["name": "walk", "frames": 1], ["name": "jump", "frames": 1],
                                         ["name": "focus", "frames": 1]]
                }
            }, .invalidManifest),
        ]
        for (name, edit, expected) in cases {
            let broken = try repack(archive, edit)
            #expect(throws: expected, "\(name)") {
                try SkinInstaller.install(archive: broken, expectedSHA256: nil, into: root)
            }
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(leftovers.isEmpty, "a rejected skin leaves nothing behind")
    }
}

extension APIClientTests {
    @Test func skinStoreFollowsTheAccountsPick() async throws {
        let root = temporaryRoot()
        let builtIn = try #require(SkinStore.builtInArchive)
        let dog = try repack(builtIn) { files in
            files["manifest.json"] = try editJSON(files["manifest.json"]) {
                $0["id"] = "pixel-dog"
                $0["name"] = "Pixel Dog"
            }
        }
        let dogSHA = SkinInstaller.sha256(of: dog)
        let settings = #"{"data":{"log_sync_paused":false,"excluded_apps":[],"skin_id":"pixel-dog"}}"#
        let dogListing = #"{"data":[{"id":"pixel-dog","name":"Pixel Dog","version":1,"sha256":"\#(dogSHA)","size":\#(dog.count)}]}"#

        let store = SkinStore(root: root)
        #expect(store.current?.isBuiltIn == true)
        var changes = 0
        store.onChange = { changes += 1 }

        // picked and granted: downloaded, installed, and shared with widgets
        StubServer.shared.reset { request in
            request.url?.path == "/api/me/settings" ? (200, settings) : (200, dogListing)
        }
        StubServer.shared.serve(dog, at: "/api/skins/pixel-dog/archive")
        await store.sync(api: client)
        #expect(store.current?.id == "pixel-dog" && store.current?.sha256 == dogSHA && changes == 1)
        #expect(store.granted.map(\.id) == ["pixel-dog"])
        #expect(SkinInstaller.current(in: root)?.id == "pixel-dog")

        await store.sync(api: client)
        #expect(StubServer.shared.count(path: "/api/skins/pixel-dog/archive") == 1, "an installed version isn't downloaded again")

        // a download that doesn't match the listing keeps the skin on screen
        let otherListing = dogListing.replacingOccurrences(of: dogSHA, with: String(repeating: "a", count: 64))
        StubServer.shared.reset { request in
            request.url?.path == "/api/me/settings" ? (200, settings) : (200, otherListing)
        }
        StubServer.shared.serve(dog, at: "/api/skins/pixel-dog/archive")
        await store.sync(api: client)
        #expect(store.current?.sha256 == dogSHA && changes == 1)

        // revoked: back to the built-in skin, and the dog's copy is deleted
        StubServer.shared.reset { request in
            request.url?.path == "/api/me/settings"
                ? (200, #"{"data":{"log_sync_paused":false,"excluded_apps":[],"skin_id":null}}"#)
                : (200, #"{"data":[]}"#)
        }
        await store.sync(api: client)
        #expect(store.current?.isBuiltIn == true && store.granted.isEmpty && changes == 2)
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("@") }
        #expect(folders == [store.current?.folder.lastPathComponent])

        // a pick that saves but can't be applied on this device (the download doesn't match) is reported
        StubServer.shared.reset { request in
            request.url?.path == "/api/me/settings" ? (200, settings) : (200, otherListing)
        }
        StubServer.shared.serve(dog, at: "/api/skins/pixel-dog/archive")
        await #expect(throws: SkinSelectionError.notApplied) {
            try await store.select("pixel-dog", api: client)
        }
        #expect(store.current?.isBuiltIn == true)
    }
}
