//
//  TimelapseLibrary.swift
//  PetCore
//

import Foundation
import Observation

/// A finished timelapse: `<id>.mp4` with `<id>.json` beside it.
public nonisolated struct Timelapse: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let startedAt: Date
    /// The focus length it was planned for, and how much of it was recorded.
    public let plannedSeconds: TimeInterval
    public let recordedSeconds: TimeInterval
    public var video: URL?

    enum CodingKeys: String, CodingKey { case id, startedAt, plannedSeconds, recordedSeconds }
}

/// This device's timelapses, newest first. Never uploaded; only the newest `keep` are kept.
@Observable
public final class TimelapseLibrary {
    public static let keep = 10

    public private(set) var videos: [Timelapse] = []
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
        reload()
    }

    public var totalBytes: Int {
        videos.compactMap { $0.video.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)
    }

    /// Moves a finished video in, then drops the oldest beyond `keep`.
    public func add(_ video: URL, startedAt: Date, plannedSeconds: TimeInterval, recordedSeconds: TimeInterval) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = Self.idFormat.string(from: startedAt) + "-" + UUID().uuidString.prefix(4)
        try FileManager.default.moveItem(at: video, to: folder.appending(path: "\(id).mp4"))
        let meta = Timelapse(id: id, startedAt: startedAt, plannedSeconds: plannedSeconds, recordedSeconds: recordedSeconds)
        try JSONEncoder().encode(meta).write(to: folder.appending(path: "\(id).json"), options: .atomic)
        reload()
        for old in videos.dropFirst(Self.keep) {
            delete(old)
        }
    }

    public func delete(_ timelapse: Timelapse) {
        for ext in ["mp4", "json"] {
            try? FileManager.default.removeItem(at: folder.appending(path: "\(timelapse.id).\(ext)"))
        }
        reload()
    }

    public func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        videos = names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: folder.appending(path: name)),
                  var meta = try? JSONDecoder().decode(Timelapse.self, from: data) else { return nil }
            let video = folder.appending(path: "\(meta.id).mp4")
            guard FileManager.default.fileExists(atPath: video.path) else { return nil }
            meta.video = video
            return meta
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private static let idFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        return format
    }()
}
