import AVFoundation
import Foundation
import Testing
@testable import PetCore

struct AudioChartTests {
    private let rate = AudioChart.rate

    /// A decaying tone burst of `frequency` starting at `time`, added into `samples`.
    private func burst(_ samples: inout [Float], at time: Double, frequency: Double, length: Double = 0.15, decay: Double = 0.04) {
        let start = Int(time * rate)
        for i in 0..<Int(length * rate) where start + i < samples.count {
            let t = Double(i) / rate
            samples[start + i] += Float(sin(2 * .pi * frequency * t) * exp(-t / decay) * 0.8)
        }
    }

    /// 30 s at 120 bpm from 1 s: kicks (80 Hz) on beats 1 and 3, hi-hats (7 kHz) on 2 and 4.
    private func groove() -> (samples: [Float], kicks: [Double], hats: [Double]) {
        var samples = [Float](repeating: 0, count: Int(32 * rate))
        var kicks: [Double] = [], hats: [Double] = []
        for beat in 0..<60 {
            let time = 1 + Double(beat) * 0.5
            if beat.isMultiple(of: 2) { kicks.append(time); burst(&samples, at: time, frequency: 80) }
            else { hats.append(time); burst(&samples, at: time, frequency: 7000, decay: 0.02) }
        }
        return (samples, kicks, hats)
    }

    @Test func findsTheTempoAndTheHitsInTheirLanes() throws {
        let (samples, kicks, hats) = groove()
        let result = try AudioChart.analyze(samples)
        #expect(abs(result.bpm - 120) < 1.5, "found \(result.bpm) bpm")
        let near = { (time: Double) in result.hard.first { abs($0.time - time) < 0.04 } }
        let foundKicks = kicks.compactMap(near), foundHats = hats.compactMap(near)
        #expect(foundKicks.count >= kicks.count - 2 && foundHats.count >= hats.count - 2)
        #expect(foundKicks.allSatisfy { $0.lane <= 1 }, "kicks on the left")
        #expect(foundHats.allSatisfy { $0.lane >= 2 }, "hi-hats on the right")
        #expect(result.hard.count <= kicks.count + hats.count + 4, "no hits made up")
        #expect(!result.easy.isEmpty && result.easy.count < result.hard.count)
        #expect(zip(result.easy, result.easy.dropFirst()).allSatisfy { $1.time - $0.time >= 0.49 })
    }

    @Test func aRingingNoteIsHeld() throws {
        var (samples, _, _) = groove()
        burst(&samples, at: 20.25, frequency: 2000, length: 2, decay: 50) // a vocal-ish note held for 2 s
        let result = try AudioChart.analyze(samples)
        let long = try #require(result.hard.first { abs($0.time - 20.25) < 0.05 })
        #expect(long.lane == 2 && long.hold > 1.2, "held \(long.hold) s")
    }

    @Test func silenceHasNoBeat() {
        #expect(throws: AudioChart.Failure.self) { try AudioChart.analyze([Float](repeating: 0, count: Int(10 * rate))) }
    }

    @Test func readsAStereoFileAtAnyRate() throws {
        let (samples, _, _) = groove()
        let url = FileManager.default.temporaryDirectory.appending(path: "groove-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count * 2)))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { // upsampled by repeating, the same in both channels
            buffer.floatChannelData![0][i] = samples[i / 2]
            buffer.floatChannelData![1][i] = samples[i / 2]
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let read = try AudioChart.read(url)
        #expect(abs(read.count - samples.count) < 4096)
        #expect(abs(try AudioChart.analyze(read).bpm - 120) < 1.5)
        #expect(throws: AudioChart.Failure.self) { try AudioChart.read(url.deletingLastPathComponent().appending(path: "missing.mp3")) }
    }
}
