//
//  RhythmLibrary.swift
//  befriend
//
//  Rhythm (M43): the songs added on the Mac. Each file is copied into befriend's folder and charted once (audio by
//  `AudioChart`, MIDI from its melody); the charts are kept beside it in index.json. The phone's song list is the
//  built-in songs plus these. Files are charted one at a time: a long recording takes a few hundred MB while it's read.
//

import Foundation
import Observation
import os
import PetCore

@MainActor @Observable
final class RhythmLibrary {
    enum Kind: String, Codable { case audio, midi }

    struct Entry: Codable, Identifiable {
        let id: String
        let title: String
        let file: String
        let kind: Kind
        let bpm: Double
        let duration: Double
        let easy: [RhythmSong.ChartNote]
        let hard: [RhythmSong.ChartNote]

        func chart(_ difficulty: RhythmSong.Difficulty) -> [RhythmSong.ChartNote] { difficulty == .easy ? easy : hard }
    }

    /// A file waiting for or being charted, or one that failed.
    struct Pending: Identifiable {
        let id = UUID()
        let title: String
        var message: String?
    }

    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "rhythm")

    private(set) var entries: [Entry] = []
    private(set) var adding: [Pending] = []
    private(set) var failures: [Pending] = []
    /// The list changed: the phone hears about it.
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var queue: [(URL, Pending)] = []
    @ObservationIgnored private var working = false
    private var index: URL { folder.appending(path: "index.json") }

    var songs: [RhythmSongInfo] { RhythmSongInfo.builtIn + entries.map { RhythmSongInfo(id: $0.id, title: $0.title, bpm: $0.bpm) } }

    init(folder: URL = MacConfig.rhythmFolder) {
        self.folder = folder
        guard let data = try? Data(contentsOf: index) else { return }
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch { // keep the old index rather than overwrite it on the next save
            Self.log.error("Rhythm's song index couldn't be read: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.moveItem(at: index, to: folder.appending(path: "index-unreadable-\(Int(Date.now.timeIntervalSince1970)).json"))
        }
    }

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
    func url(of entry: Entry) -> URL { folder.appending(path: entry.file) }

    func add(_ urls: [URL]) {
        failures = []
        let items = urls.map { ($0, Pending(title: $0.deletingPathExtension().lastPathComponent)) }
        adding += items.map(\.1)
        queue += items
        guard !working else { return }
        working = true
        Task {
            while !queue.isEmpty {
                let (url, pending) = queue.removeFirst()
                await add(url, pending)
                adding.removeAll { $0.id == pending.id }
            }
            working = false
        }
    }

    func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: url(of: entry))
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func add(_ source: URL, _ pending: Pending) async {
        let id = UUID().uuidString, title = pending.title, folder = folder
        let stored = folder.appending(path: source.pathExtension.isEmpty ? id : "\(id).\(source.pathExtension.lowercased())")
        do {
            // Off the main actor: copying and reading a long recording takes a while.
            let entry = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: source, to: stored)
                return try Self.chart(stored, id: id, title: title)
            }.value
            entries.append(entry)
            save()
        } catch {
            try? FileManager.default.removeItem(at: stored)
            failures.append(Pending(title: title, message: error.localizedDescription))
        }
    }

    /// MIDI by its header, whatever the extension; anything else as audio. A thin Easy chart (loosely played or
    /// unusual songs) is made from Hard instead.
    nonisolated private static func chart(_ url: URL, id: String, title: String) throws -> Entry {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let entry: Entry
        if data.prefix(4) == Data("MThd".utf8) {
            let song = try RhythmSong.load(midi: data, id: id, title: title)
            entry = Entry(id: id, title: title, file: url.lastPathComponent, kind: .midi, bpm: song.bpm.rounded(),
                          duration: song.duration, easy: song.chart(.easy), hard: song.chart(.hard))
        } else {
            let result = try AudioChart.analyze(AudioChart.read(url))
            entry = Entry(id: id, title: title, file: url.lastPathComponent, kind: .audio, bpm: result.bpm.rounded(),
                          duration: result.duration, easy: result.easy, hard: result.hard)
        }
        guard !entry.hard.isEmpty else { throw AudioChart.Failure.noBeat }
        guard entry.easy.count < max(8, entry.hard.count / 8) else { return entry }
        return Entry(id: id, title: title, file: entry.file, kind: entry.kind, bpm: entry.bpm, duration: entry.duration,
                     easy: RhythmSong.thinned(entry.hard, gap: max(0.5, 60 / entry.bpm)), hard: entry.hard)
    }

    private func save() {
        do {
            try JSONEncoder().encode(entries).write(to: index, options: .atomic)
        } catch {
            Self.log.error("Rhythm's song index couldn't be saved: \(error.localizedDescription, privacy: .public)")
        }
        onChange()
    }
}
