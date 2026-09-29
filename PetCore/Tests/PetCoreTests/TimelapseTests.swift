import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PetCore

private func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "timelapse-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Appends synthetic camera frames, waiting out the encoder like a real 1-second tick would.
private func write(_ count: Int, into writer: TimelapseWriter, portrait: Bool = false) async throws {
    let extent = portrait ? CGRect(x: 0, y: 0, width: 720, height: 1280) : CGRect(x: 0, y: 0, width: 1280, height: 720)
    while writer.frames < count {
        let shade = Double(writer.frames) / Double(count)
        let frame = CIImage(color: CIColor(red: shade, green: 0.4, blue: 1 - shade)).cropped(to: extent)
        if try !writer.append(frame, overlay: nil) { try await Task.sleep(for: .milliseconds(5)) }
    }
}

private func video(_ url: URL) async throws -> (seconds: Double, size: CGSize) {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    return (try await asset.load(.duration).seconds, try await track.load(.naturalSize))
}

struct TimelapseTests {
    @Test func framesAreSpreadAcrossThePlannedFocus() {
        #expect(abs(TimelapsePlan.interval(for: 25 * 60) - 0.8333) < 0.001)
        #expect(TimelapsePlan.interval(for: 180 * 60) == 6)
        #expect(TimelapsePlan.interval(for: 60) == TimelapsePlan.minInterval, "a 1-minute focus plays slower instead")
        #expect(TimelapsePlan.size(for: CGRect(x: 0, y: 0, width: 3840, height: 2160)) == CGSize(width: 3840, height: 2160), "full resolution")
        #expect(TimelapsePlan.size(for: CGRect(x: 0, y: 0, width: 1081, height: 1921)) == CGSize(width: 1080, height: 1920), "even for H.264")
    }

    // A 2-second "minute" keeps the test fast; the maths is the same.
    @Test func aFullFocusAndAnEarlyEndBothLastTheLength() async throws {
        let dir = scratch()
        for (frames, portrait) in [(60, false), (20, true)] {
            let writer = TimelapseWriter(rawURL: dir.appending(path: "raw-\(frames).mp4"), length: 2, fps: 30)
            try await write(frames, into: writer, portrait: portrait)
            let out = dir.appending(path: "out-\(frames).mp4")
            #expect(try await writer.finish(to: out))
            let result = try await video(out)
            #expect(abs(result.seconds - 2) < 0.1, "\(frames) frames lasted \(result.seconds) s")
            #expect(result.size == (portrait ? CGSize(width: 720, height: 1280) : CGSize(width: 1280, height: 720)))
        }
        let empty = TimelapseWriter(rawURL: dir.appending(path: "raw-empty.mp4"), length: 2, fps: 30)
        #expect(try await !empty.finish(to: dir.appending(path: "none.mp4")), "a focus with no frames makes no video")
    }

    @Test func theOverlayCoversTheFrame() throws {
        let skin = try SkinInstaller.install(archive: try #require(SkinStore.builtInArchive), expectedSHA256: nil, into: scratch())
        let clip = skin.clip(InstalledSkin.focus, "default")
        let size = CGSize(width: 1280, height: 720)
        let overlay = try #require(TimelapseOverlay(size: size, friend: skin.frame(clip, 0), clock: "12:40 / 25:00").image())
        #expect(overlay.extent.size == size)
        let dir = scratch()
        let writer = TimelapseWriter(rawURL: dir.appending(path: "raw.mp4"), length: 1, fps: 30)
        let frame = CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size))
        #expect(try writer.append(frame, overlay: overlay), "the overlay composites onto a camera frame")
        writer.cancel()
    }

    @Test func theLibraryKeepsTheNewestNine() throws {
        let dir = scratch()
        let library = TimelapseLibrary(folder: dir.appending(path: "Timelapses"))
        for i in 0..<12 {
            let file = dir.appending(path: "v\(i).mp4")
            try Data([0, 1, 2]).write(to: file)
            try library.add(file, startedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 3600),
                            plannedSeconds: 1500, recordedSeconds: 1500)
        }
        #expect(library.videos.count == TimelapseLibrary.keep)
        #expect(library.videos.first?.startedAt == Date(timeIntervalSince1970: 1_800_000_000 + 11 * 3600), "newest first")
        #expect(library.totalBytes == 27)
        library.delete(try #require(library.videos.first))
        #expect(library.videos.count == 8)
        #expect(TimelapseLibrary(folder: dir.appending(path: "Timelapses")).videos.count == 8, "survives a relaunch")
    }

    @Test func aLibraryFromWhenTenWereKeptDropsTheOldest() throws {
        let folder = scratch().appending(path: "Timelapses", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<10 {
            let meta = Timelapse(id: "v\(i)", startedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 3600),
                                 plannedSeconds: 1500, recordedSeconds: 1500)
            try JSONEncoder().encode(meta).write(to: folder.appending(path: "v\(i).json"))
            try Data([0]).write(to: folder.appending(path: "v\(i).mp4"))
        }
        let library = TimelapseLibrary(folder: folder)
        #expect(library.videos.count == 9 && library.videos.last?.id == "v1", "v0, the oldest, is gone")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "v0.mp4").path))
    }

    @Test func theControllerFollowsTheFocus() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let on = Pomodoro(settings: .init(recordTimelapse: true))
        let running = on.start(at: t0)
        func action(_ p: Pomodoro, _ state: TimelapseRecorder.State, phase: Int? = 0, away: Bool = false) -> TimelapseController.Action {
            TimelapseController.action(for: p, recorder: state, recordingPhase: phase, away: away)
        }
        #expect(action(Pomodoro().start(at: t0), .idle) == .none, "off by default")
        #expect(action(running, .recording) == .none)
        #expect(action(running.pause(at: t0 + 60), .recording) == .pause)
        #expect(action(running, .paused) == .resume)
        #expect(action(running, .recording, away: true) == .pause, "asleep, or the iPhone app off screen")
        #expect(action(running.stop(), .recording) == .finish, "stopping early files the video")
        #expect(action(running.stop(), .paused) == .finish)
        #expect(action(running, .recording, phase: 8) == .finish, "another focus ended this one")
        let next = running.stop().start(at: t0)
        #expect(next.phaseID == 1 && action(next, .recording) == .finish, "the next focus gets its own video")
        #expect(action(running.with(settings: running.settings.with(recordTimelapse: false)), .recording) == .finish)
        #expect(action(on, .idle) == .none, "a focus that hasn't started")
    }

    @Test func aPomodoroSavedBeforeTimelapsesStillLoads() throws {
        let saved = try JSONEncoder().encode(Pomodoro())
        var raw = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var settings = try #require(raw["settings"] as? [String: Any])
        settings["recordTimelapse"] = nil
        raw["settings"] = settings
        let old = try JSONDecoder().decode(Pomodoro.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(!old.settings.recordTimelapse)
    }
}
