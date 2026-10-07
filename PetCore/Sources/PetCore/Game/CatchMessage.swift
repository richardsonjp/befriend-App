//
//  CatchMessage.swift
//  PetCore
//
//  What the iPhone controller and the Mac games (Catch M41, Runner M42, Rhythm M43) say to each other over the
//  nearby peer.
//

import Foundation

public nonisolated enum CatchMessage: Codable, Equatable, Sendable {
    // iPhone → Mac
    case start(MacGame, rhythm: RhythmPick? = nil)
    case input(steer: Double, jump: Bool, drop: Bool = false) // steer -1…1; jump/drop while their pad is held
    case lane(RhythmTouch)
    case ping(Double) // the phone's clock; the Mac answers at once
    case calibrate // play the tap-along clicks
    case pause
    case resume
    case quit
    // Mac → iPhone
    case state(CatchStatus)
    case hit(CatchHit)
    case pong(sent: Double, mac: Double)
    case clicks([Double]) // when each calibration click plays, on the Mac's clock
    case songs([RhythmSongInfo]) // what Rhythm can play: the built-in songs and the ones added on the Mac
    case link(CatchLink) // where to send tilt over the fast lane
}

public nonisolated enum MacGame: String, Codable, Sendable, CaseIterable {
    case catchFood = "catch"
    case runner
    case rhythm

    public var title: String { rawValue == "catch" ? "Catch" : rawValue.capitalized }
}

public nonisolated struct RhythmSongInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var bpm: Double

    public init(id: String, title: String, bpm: Double) {
        self.id = id
        self.title = title
        self.bpm = bpm
    }

    public static let builtIn = RhythmSong.all.map { RhythmSongInfo(id: $0.id, title: $0.title, bpm: $0.bpm) }
}

/// The song to play, and how late this player taps along to what they hear (seconds).
public nonisolated struct RhythmPick: Codable, Equatable, Sendable {
    public var song: String
    public var difficulty: RhythmSong.Difficulty
    public var calibration: Double

    public init(song: String, difficulty: RhythmSong.Difficulty, calibration: Double) {
        self.song = song
        self.difficulty = difficulty
        self.calibration = calibration
    }
}

/// A lane pressed or let go, stamped on the Mac's clock when it happened (`systemUptime` + the synced offset).
public nonisolated struct RhythmTouch: Codable, Equatable, Sendable {
    public var lane: Int
    public var down: Bool
    public var at: Double

    public init(lane: Int, down: Bool, at: Double) {
        self.lane = lane
        self.down = down
        self.at = at
    }
}

public nonisolated struct CatchStatus: Codable, Equatable, Sendable {
    public var score: Int
    public var lives: Int
    public var best: Int
    public var paused: Bool
    public var over: Bool
    /// Rhythm only.
    public var rhythm: RhythmStatus?

    public init(score: Int, lives: Int, best: Int, paused: Bool, over: Bool, rhythm: RhythmStatus? = nil) {
        self.score = score
        self.lives = lives
        self.best = best
        self.paused = paused
        self.over = over
        self.rhythm = rhythm
    }
}

public nonisolated struct RhythmStatus: Codable, Equatable, Sendable {
    public var health: Double
    public var combo: Int
    public var accuracy: Double
    public var grade: String
    public var failed: Bool

    public init(health: Double, combo: Int, accuracy: Double, grade: String, failed: Bool) {
        self.health = health
        self.combo = combo
        self.accuracy = accuracy
        self.grade = grade
        self.failed = failed
    }
}

public nonisolated enum CatchHit: String, Codable, Sendable {
    case food
    case bomb
}
