//
//  RhythmSong.swift
//  PetCore
//
//  Rhythm (M43): the built-in songs, written in code as note lists that the Mac plays through the General MIDI sounds
//  macOS ships. The note charts come from each song's melody, so the lanes always match what you hear.
//

import Foundation

public nonisolated struct RhythmSong: Sendable, Identifiable {
    public struct Note: Equatable, Sendable {
        public var beat: Double
        public var length: Double // beats
        public var pitch: UInt8
        public var velocity: UInt8
    }

    public struct Part: Sendable {
        /// General MIDI program (0-based); ignored for drums.
        public var program: UInt8
        public var drums: Bool
        public var notes: [Note]
    }

    public enum Difficulty: String, Codable, Sendable, CaseIterable {
        case easy, hard
        public var title: String { rawValue.capitalized }
    }

    public struct ChartNote: Equatable, Sendable {
        public var time: Double // seconds from the song's start
        public var lane: Int // 0…3
        public var hold: Double // seconds; 0 is a tap
    }

    public static let lanes = 4

    public let id: String
    public let title: String
    public let bpm: Double
    /// `parts[0]` is the melody the chart follows.
    public let parts: [Part]

    public var duration: Double { seconds(parts.flatMap(\.notes).map { $0.beat + $0.length }.max() ?? 0) }
    public func seconds(_ beat: Double) -> Double { beat * 60 / bpm }

    public static let all: [RhythmSong] = [
        compose(id: "sunny", title: "Sunny Walk", bpm: 92, key: 60, minor: false, chords: [0, 4, 5, 3],
                lead: 12, bass: 33, pad: 89, seed: 11), // marimba, finger bass, warm pad
        compose(id: "night", title: "Night Drive", bpm: 118, key: 57, minor: true, chords: [0, 5, 2, 6],
                lead: 81, bass: 38, pad: 88, seed: 23), // saw lead, synth bass, new age pad
        compose(id: "zoomies", title: "Zoomies", bpm: 148, key: 62, minor: false, chords: [0, 3, 4, 4],
                lead: 80, bass: 34, pad: 90, seed: 37), // square lead, picked bass, polysynth
    ]

    public static func named(_ id: String) -> RhythmSong? { all.first { $0.id == id } }

    /// Eight clicks a beat apart at 100 bpm, starting on beat 2, for the phone's tap-along calibration.
    public static let clicks = RhythmSong(id: "clicks", title: "Clicks", bpm: 100, parts: [
        Part(program: 0, drums: true, notes: (0..<8).map { Note(beat: Double(2 + $0), length: 0.25, pitch: 76, velocity: 120) }),
    ])

    // MARK: Charts

    /// Hard: every melody note, its lane by pitch (low left, high right), long notes held. Easy: only the notes on the
    /// bar's strong beats (1 and 3), at least two beats apart.
    public func chart(_ difficulty: Difficulty) -> [ChartNote] {
        let melody = parts[0].notes.sorted { $0.beat < $1.beat }
        guard let low = melody.map(\.pitch).min(), let high = melody.map(\.pitch).max() else { return [] }
        var lastBeat = -Double.infinity
        return melody.compactMap { note in
            if difficulty == .easy {
                guard note.beat.truncatingRemainder(dividingBy: 2) == 0, note.beat - lastBeat >= 2 else { return nil }
            }
            lastBeat = note.beat
            let lane = min(Self.lanes - 1, Int(note.pitch - low) * Self.lanes / (Int(high - low) + 1))
            return ChartNote(time: seconds(note.beat), lane: lane, hold: note.length >= 1.5 ? seconds(note.length - 0.5) : 0)
        }
    }

    // MARK: Composing

    /// Sections of 8 bars: an intro of drums and bass (time to get ready), the A tune twice, B, A twice, an ending.
    /// A section's melody comes from its own seed, so every A sounds the same and can be learned.
    static func compose(id: String, title: String, bpm: Double, key: UInt8, minor: Bool, chords: [Int],
                        lead: UInt8, bass: UInt8, pad: UInt8, seed: UInt64) -> RhythmSong {
        let scale = minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        func pitch(_ step: Int, octave: Int) -> UInt8 { // a scale step (any integer) above `key` + octaves
            let wrapped = ((step % 7) + 7) % 7
            return UInt8(Int(key) + 12 * (octave + (step - wrapped) / 7) + scale[wrapped])
        }
        let sections: [Character] = ["I", "A", "A", "B", "A", "A", "O"]
        var melody: [Note] = [], bassLine: [Note] = [], pads: [Note] = [], drums: [Note] = []
        for (index, section) in sections.enumerated() {
            let start = Double(index * 32)
            var rng = SeededGenerator(seed: seed &+ UInt64(section.asciiValue ?? 0))
            var step = section == "B" ? 9 : 7 // B sits higher
            for bar in 0..<8 {
                let barStart = start + Double(bar * 4)
                let chord = chords[bar % chords.count]
                bassLine += [0.0, 2].map { Note(beat: barStart + $0, length: 1.5, pitch: pitch(chord, octave: -2), velocity: 95) }
                pads += [0, 2, 4].map { Note(beat: barStart, length: 4, pitch: pitch(chord + $0, octave: -1), velocity: 55) }
                drums += Self.drumBar(at: barStart, last: section == "O" && bar == 7)
                guard section != "I" else { continue }
                let cell = section == "O" && bar >= 6 ? [4.0] : Self.cells.randomElement(using: &rng)!
                var offset = 0.0
                for length in cell {
                    if offset.truncatingRemainder(dividingBy: 2) == 0 { // strong beats land on the chord
                        let tones = [chord, chord + 2, chord + 4, chord + 7, chord + 9]
                        step = tones.min { abs($0 - step) < abs($1 - step) }!
                    } else {
                        step += [-2, -1, -1, 1, 1, 2].randomElement(using: &rng)!
                    }
                    step = max(3, min(13, step))
                    melody.append(Note(beat: barStart + offset, length: length, pitch: pitch(step, octave: 0), velocity: 110))
                    offset += length
                }
            }
        }
        return RhythmSong(id: id, title: title, bpm: bpm, parts: [
            Part(program: lead, drums: false, notes: melody),
            Part(program: bass, drums: false, notes: bassLine),
            Part(program: pad, drums: false, notes: pads),
            Part(program: 0, drums: true, notes: drums),
        ])
    }

    /// One bar's rhythms, in beats; the 2s become held notes.
    private static let cells: [[Double]] = [
        [1, 1, 1, 1], [1, 1, 2], [0.5, 0.5, 1, 1, 1], [1.5, 0.5, 2], [2, 1, 1], [1, 0.5, 0.5, 2], [0.5, 0.5, 0.5, 0.5, 1, 1],
    ]

    /// Kick on 1 and 3, snare on 2 and 4, hi-hat on every half beat; a crash to end.
    private static func drumBar(at start: Double, last: Bool) -> [Note] {
        let hats = (0..<8).map { Note(beat: start + Double($0) / 2, length: 0.25, pitch: 42, velocity: 60) }
        let kicks = [0.0, 2].map { Note(beat: start + $0, length: 0.25, pitch: 36, velocity: 100) }
        let snares = [1.0, 3].map { Note(beat: start + $0, length: 0.25, pitch: 38, velocity: 90) }
        let crash = last ? [Note(beat: start + 4, length: 2, pitch: 49, velocity: 110)] : []
        return hats + kicks + snares + crash
    }
}
