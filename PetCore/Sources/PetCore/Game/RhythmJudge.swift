//
//  RhythmJudge.swift
//  PetCore
//
//  Rhythm (M43): judges the phone's presses and releases against a chart. Times are song seconds, already corrected
//  for the clocks and the player's calibration, so a press that arrives late over the network still counts at the
//  moment it was made. A note is only called a miss `grace` after its window closes, so late messages aren't missed.
//

import Foundation

public nonisolated struct RhythmJudge: Sendable {
    public enum Judgement: String, Codable, Sendable {
        case perfect, great, good, miss

        public var title: String { rawValue.capitalized }
        var points: Int { [.perfect: 300, .great: 200, .good: 100][self] ?? 0 }
        var accuracy: Double { [.perfect: 1, .great: 0.67, .good: 0.33][self] ?? 0 }
        var health: Double { [.perfect: 0.03, .great: 0.02, .good: 0.01][self] ?? -0.08 }
    }

    public enum Event: Equatable, Sendable {
        case judged(note: Int, Judgement)
        /// Let go before the end of a hold.
        case broke(note: Int)
        case held(note: Int)
        case failed
        case finished
    }

    public static let windows: [(Judgement, Double)] = [(.perfect, 0.045), (.great, 0.09), (.good, 0.135)]
    static let grace = 0.3
    static let holdBonus = 100
    static let brokenHealth = -0.05

    public let notes: [RhythmSong.ChartNote]
    public private(set) var judged: [Judgement?]
    /// The hold being played in each lane, by note index.
    public private(set) var holding: [Int?] = Array(repeating: nil, count: RhythmSong.lanes)
    public private(set) var pressed: [Bool] = Array(repeating: false, count: RhythmSong.lanes)
    public private(set) var score = 0
    public private(set) var combo = 0
    public private(set) var health = 1.0
    public private(set) var isDone = false
    public private(set) var failed = false
    private var holdsDone: Set<Int> = []

    public init(notes: [RhythmSong.ChartNote]) {
        self.notes = notes
        judged = Array(repeating: nil, count: notes.count)
    }

    /// Share of the best possible, 0…1, over the notes judged so far.
    public var accuracy: Double {
        let done = judged.compactMap { $0 }
        return done.isEmpty ? 1 : done.map(\.accuracy).reduce(0, +) / Double(done.count)
    }

    public var grade: String {
        if failed { return "F" }
        return accuracy >= 0.95 ? "S" : accuracy >= 0.85 ? "A" : accuracy >= 0.7 ? "B" : "C"
    }

    public mutating func press(lane: Int, at time: Double) -> [Event] {
        guard !isDone, (0..<RhythmSong.lanes).contains(lane) else { return [] }
        pressed[lane] = true
        let good = Self.windows.last!.1
        // The earliest open note in this lane within reach; a stray tap costs nothing.
        guard let index = notes.indices.first(where: { judged[$0] == nil && notes[$0].lane == lane && abs(notes[$0].time - time) <= good })
        else { return [] }
        let offset = abs(notes[index].time - time)
        let judgement = Self.windows.first { offset <= $0.1 }!.0
        // A release that never came (lost, or an older hold still open): settle that hold first.
        let earlier = holding[lane] == nil ? [] : release(lane: lane, at: time)
        pressed[lane] = true
        if notes[index].hold > 0 { holding[lane] = index }
        return earlier + record(index, judgement)
    }

    public mutating func release(lane: Int, at time: Double) -> [Event] {
        guard !isDone, (0..<RhythmSong.lanes).contains(lane) else { return [] }
        pressed[lane] = false
        guard let index = holding[lane] else { return [] }
        holding[lane] = nil
        let note = notes[index]
        if time >= note.time + note.hold - Self.windows.last!.1 { return finishHold(index) }
        combo = 0
        health = max(0, health + Self.brokenHealth)
        return [.broke(note: index)] + checkFailed()
    }

    /// The song reached `time`: notes nobody played are missed, holds still held to their end are done.
    public mutating func advance(to time: Double) -> [Event] {
        guard !isDone else { return [] }
        var events: [Event] = []
        let late = Self.windows.last!.1 + Self.grace
        for index in notes.indices where judged[index] == nil && notes[index].time + late < time && !isDone {
            events += record(index, .miss)
        }
        for lane in holding.indices {
            guard let index = holding[lane], notes[index].time + notes[index].hold + Self.grace < time else { continue }
            holding[lane] = nil
            events += finishHold(index)
        }
        if isDone { return events }
        if time > (notes.map { $0.time + $0.hold }.max() ?? 0) + late + 1 { // an empty chart ends too
            isDone = true
            events.append(.finished)
        }
        return events
    }

    private mutating func record(_ index: Int, _ judgement: Judgement) -> [Event] {
        judged[index] = judgement
        score += judgement.points
        combo = judgement == .miss ? 0 : combo + 1
        health = min(1, max(0, health + judgement.health))
        return [.judged(note: index, judgement)] + checkFailed()
    }

    private mutating func finishHold(_ index: Int) -> [Event] {
        guard holdsDone.insert(index).inserted else { return [] }
        score += Self.holdBonus
        return [.held(note: index)]
    }

    private mutating func checkFailed() -> [Event] {
        guard health <= 0, !isDone else { return [] }
        isDone = true
        failed = true
        return [.failed]
    }

    // MARK: Clocks

    /// The other device's clock offset from the round trip with the shortest time: theirs ≈ mine + offset.
    /// Each sample is (sent, their time, received), with sent and received on my clock.
    public static func clockOffset(_ samples: [(sent: Double, theirs: Double, received: Double)]) -> Double? {
        samples.min { $0.received - $0.sent < $1.received - $1.sent }.map { $0.theirs - ($0.sent + $0.received) / 2 }
    }

    /// How late the player taps along to clicks they hear (speaker or AirPods delay plus habit), as the median of each
    /// tap's distance to its nearest click. Clamped to 0…0.4 s; nil without at least 4 taps.
    public static func calibration(taps: [Double], clicks: [Double]) -> Double? {
        guard taps.count >= 4, !clicks.isEmpty else { return nil }
        let offsets = taps.map { tap in tap - clicks.min { abs($0 - tap) < abs($1 - tap) }! }.sorted()
        return max(0, min(0.4, offsets[offsets.count / 2]))
    }
}
