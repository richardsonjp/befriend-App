//
//  AudioChart.swift
//  PetCore
//
//  Rhythm (M43) for the user's own recordings (MP3, M4A, WAV, AIFF): finds the hits in the song and charts them.
//  The audio is split into four bands (kick and bass, low mids, vocals and snare, hi-hats); a jump in a band's level is
//  a hit, and the band picks the lane. The tempo is the steady beat that lines up with the most hits, and hits near the
//  beat grid snap to it. A band that rings on after its hit becomes a hold. All on-device, with Accelerate.
//

import Accelerate
import AVFoundation
import Foundation

public nonisolated enum AudioChart {
    public struct Result: Sendable {
        public var bpm: Double
        public var duration: Double
        public var easy: [RhythmSong.ChartNote]
        public var hard: [RhythmSong.ChartNote]
    }

    public enum Failure: LocalizedError {
        case unreadable
        case tooLong
        case noBeat

        public var errorDescription: String? {
            switch self {
            case .unreadable: "That file couldn't be read as audio."
            case .tooLong: "Songs up to 15 minutes work; that one is longer."
            case .noBeat: "No beat was found in that song, so there's nothing to play along to."
            }
        }
    }

    static let rate = 22_050.0
    static let hop = 512 // 23 ms frames
    static var frameSeconds: Double { Double(hop) / rate }
    /// Band centre (Hz) and Q, low to high: the lanes left to right.
    static let bands: [(centre: Double, q: Double)] = [(90, 0.8), (450, 1), (2000, 1), (7000, 0.9)]
    static let snapWithin = 0.05 // seconds from the grid that still snap to it
    static let minGap = 0.14 // Hard: at most about 7 notes a second
    static let maxLength = 15 * 60.0

    /// The file as mono samples at `rate`.
    public static func read(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.unreadable }
        let format = file.processingFormat
        guard Double(file.length) / format.sampleRate <= maxLength else { throw Failure.tooLong }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              let converted = AVAudioPCMBuffer(pcmFormat: output,
                                               frameCapacity: AVAudioFrameCount(Double(file.length) * rate / format.sampleRate) + 4096)
        else { throw Failure.unreadable }
        do { try file.read(into: input) } catch { throw Failure.unreadable }
        converter.downmix = true
        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            defer { fed = true }
            status.pointee = fed ? .endOfStream : .haveData
            return fed ? nil : input
        }
        guard error == nil, let channel = converted.floatChannelData?[0] else { throw Failure.unreadable }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    public static func analyze(_ samples: [Float]) throws -> Result {
        let frames = samples.count / hop
        guard frames > 100 else { throw Failure.noBeat }
        // Each band's level per frame, and how much it jumped (normalized, so quiet hi-hats count as much as kicks).
        let energy = bands.map { band in levels(of: bandpass(samples, centre: band.centre, q: band.q), frames: frames) }
        let flux = energy.map { band -> [Float] in
            let level = band.map { log1p(1000 * $0) }
            let rise = [0] + zip(level, level.dropFirst()).map { max(0, $1 - $0) }
            let mean = rise.reduce(0, +) / Float(rise.count)
            return mean > 0 ? rise.map { $0 / mean } : rise
        }
        let onset = (0..<frames).map { frame in flux.reduce(0) { $0 + $1[frame] } }
        let hits = peaks(onset)
        guard hits.count >= 8, let beat = beatGrid(onset) else { throw Failure.noBeat }

        let quarter = beat.period / 4
        func snapped(_ time: Double, to step: Double) -> Double? {
            let grid = beat.first + ((time - beat.first) / step).rounded() * step
            return abs(grid - time) <= snapWithin ? grid : nil
        }
        // Hard: every hit, snapped to the nearest quarter beat when close, keeping the stronger of two too close.
        var hard: [(note: RhythmSong.ChartNote, strength: Float, frame: Int)] = []
        for frame in hits {
            let raw = (Double(frame) + 0.5) * frameSeconds // the rise happens somewhere in the frame
            let lane = flux.indices.max { flux[$0][frame] < flux[$1][frame] }!
            let note = RhythmSong.ChartNote(time: snapped(raw, to: quarter) ?? raw, lane: lane, hold: 0)
            if let last = hard.last, note.time - last.note.time < minGap {
                if onset[frame] > last.strength { hard[hard.count - 1] = (note, onset[frame], frame) }
                continue
            }
            hard.append((note, onset[frame], frame))
        }
        let held = holds(hard.map { ($0.note, $0.frame) }, energy: energy)
        let hardNotes = zip(hard, held).map { item, hold in
            RhythmSong.ChartNote(time: item.note.time, lane: item.note.lane, hold: hold)
        }
        // Easy: the stronger half, only on a beat, at least a beat (and 0.4 s) apart.
        let median = hard.map(\.strength).sorted()[hard.count / 2]
        var easy: [RhythmSong.ChartNote] = []
        for (item, note) in zip(hard, hardNotes) where item.strength >= median {
            guard let time = snapped(note.time, to: beat.period),
                  time - (easy.last?.time ?? -.infinity) >= max(beat.period, 0.4) * 0.99 else { continue }
            easy.append(RhythmSong.ChartNote(time: time, lane: note.lane, hold: note.hold))
        }
        return Result(bpm: 60 / beat.period, duration: Double(samples.count) / rate, easy: easy, hard: hardNotes)
    }

    // MARK: Steps

    private static func bandpass(_ samples: [Float], centre: Double, q: Double) -> [Float] {
        // RBJ cookbook band-pass, 0 dB peak.
        let w = 2 * Double.pi * centre / rate, alpha = sin(w) / (2 * q), a0 = 1 + alpha
        guard var filter = vDSP.Biquad(coefficients: [alpha / a0, 0, -alpha / a0, -2 * cos(w) / a0, (1 - alpha) / a0],
                                       channelCount: 1, sectionCount: 1, ofType: Float.self) else { return samples }
        return filter.apply(input: samples)
    }

    private static func levels(of samples: [Float], frames: Int) -> [Float] {
        (0..<frames).map { vDSP.meanSquare(samples[$0 * hop ..< ($0 + 1) * hop]) }
    }

    /// Frames where the onset curve peaks well above its surroundings, at least `minGap` apart.
    static func peaks(_ onset: [Float]) -> [Int] {
        let top = onset.max() ?? 0, gap = Int(minGap / frameSeconds), around = 16
        var found: [Int] = []
        for frame in onset.indices.dropFirst().dropLast() where onset[frame] > 0 {
            let near = onset[max(0, frame - 3)...min(onset.count - 1, frame + 3)]
            guard onset[frame] == near.max() else { continue }
            let window = onset[max(0, frame - around)...min(onset.count - 1, frame + around)]
            guard onset[frame] > window.reduce(0, +) / Float(window.count) * 1.5 + top * 0.05 else { continue }
            if let last = found.last, frame - last < gap {
                if onset[frame] > onset[last] { found[found.count - 1] = frame }
                continue
            }
            found.append(frame)
        }
        return found
    }

    /// The steady beat (seconds per beat, and the first beat's time) that lines up with the most onset, 70–180 bpm,
    /// leaning towards 120 so a song isn't read at half or double its speed.
    static func beatGrid(_ onset: [Float]) -> (period: Double, first: Double)? {
        let mean = onset.reduce(0, +) / Float(onset.count)
        let centred = onset.map { $0 - mean }
        let shortest = Int((60 / 180) / frameSeconds), longest = Int((60 / 70) / frameSeconds)
        guard centred.count > longest * 4 else { return nil }
        let coarse = (shortest...longest).max { a, b in
            preference(lag: Double(a)) * correlation(centred, lag: a) < preference(lag: Double(b)) * correlation(centred, lag: b)
        }!
        // Fine: the fractional period and phase whose beats land on the most onset across the whole song.
        var best = (score: -Float.infinity, period: Double(coarse), phase: 0.0)
        for step in -50...50 {
            let period = Double(coarse) + Double(step) * 0.02
            for phase in 0..<Int(period) {
                var score: Float = 0, at = Double(phase)
                while Int(at.rounded()) < onset.count {
                    score += onset[Int(at.rounded())]
                    at += period
                }
                if score > best.score { best = (score, period, Double(phase)) }
            }
        }
        return (best.period * frameSeconds, best.phase * frameSeconds)
    }

    private static func correlation(_ values: [Float], lag: Int) -> Double {
        Double(vDSP.dot(Array(values.dropLast(lag)), Array(values.dropFirst(lag))))
    }

    private static func preference(lag: Double) -> Double {
        let bpm = 60 / (lag * frameSeconds)
        return exp(-0.5 * pow(log2(bpm / 120) / 0.7, 2))
    }

    /// How long each note rings: its band stays above 60% of its level just after the hit for at least 0.6 s, without
    /// running into the next note in its lane. At most one note in six is held (the longest).
    private static func holds(_ notes: [(note: RhythmSong.ChartNote, frame: Int)], energy: [[Float]]) -> [Double] {
        var lengths = notes.indices.map { index -> Double in
            let (note, frame) = notes[index]
            let band = energy[note.lane], start = min(frame + 2, band.count - 1), level = band[start]
            let next = notes[(index + 1)...].first { $0.note.lane == note.lane }?.note.time ?? .infinity
            var end = start
            while end + 1 < band.count, band[end + 1] >= level * 0.6, Double(end + 1) * frameSeconds < next - 0.15 { end += 1 }
            let length = Double(end - frame) * frameSeconds
            return length >= 0.6 ? min(length, 4) : 0
        }
        let allowed = notes.count / 6
        if lengths.filter({ $0 > 0 }).count > allowed {
            let cutoff = lengths.sorted(by: >)[max(0, allowed - 1)]
            var kept = 0
            lengths = lengths.map { length in
                guard length >= cutoff, length > 0, kept < allowed else { return 0 }
                kept += 1
                return length
            }
        }
        return lengths
    }
}
