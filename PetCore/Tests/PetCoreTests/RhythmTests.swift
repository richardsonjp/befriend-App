import Foundation
import Testing
@testable import PetCore

struct RhythmTests {
    private func note(_ time: Double, lane: Int = 0, hold: Double = 0) -> RhythmSong.ChartNote {
        .init(time: time, lane: lane, hold: hold)
    }

    @Test func songsMakePlayableCharts() {
        for song in RhythmSong.all {
            let hard = song.chart(.hard), easy = song.chart(.easy)
            #expect((85...160).contains(song.duration), "\(song.title) is \(song.duration) s")
            #expect(hard.map(\.time) == hard.map(\.time).sorted())
            #expect(Set(hard.map(\.lane)) == [0, 1, 2, 3], "every lane gets used")
            #expect(hard.contains { $0.hold > 0 }, "some notes are held")
            #expect(hard.first!.time >= 5, "the intro gives time to get ready")
            #expect(easy.count < hard.count * 2 / 3)
            #expect(easy.allSatisfy { hard.contains($0) }, "Easy is part of Hard")
            #expect(zip(easy, easy.dropFirst()).allSatisfy { $1.time - $0.time >= song.seconds(2) - 0.0001 })
        }
        #expect(RhythmSong.all.map(\.bpm) == RhythmSong.all.map(\.bpm).sorted(), "slow, mid, fast")
    }

    @Test func pressesAreJudgedByHowCloseTheyAre() {
        var judge = RhythmJudge(notes: [note(1), note(2), note(3), note(4, lane: 1)])
        #expect(judge.press(lane: 0, at: 1.03) == [.judged(note: 0, .perfect)])
        #expect(judge.press(lane: 0, at: 1.93) == [.judged(note: 1, .great)])
        #expect(judge.press(lane: 0, at: 3.12) == [.judged(note: 2, .good)])
        #expect(judge.press(lane: 0, at: 4).isEmpty, "the wrong lane is a stray tap, not a hit")
        #expect(judge.combo == 3 && judge.score == 600)
    }

    @Test func aNoteIsMissedOnlyAfterTheGrace() {
        var judge = RhythmJudge(notes: [note(1), note(2)])
        #expect(judge.advance(to: 1.3).isEmpty, "a press may still be on its way")
        #expect(judge.press(lane: 0, at: 1.01) == [.judged(note: 0, .perfect)], "a late message still counts")
        #expect(judge.advance(to: 2.5) == [.judged(note: 1, .miss)])
        #expect(judge.combo == 0)
    }

    @Test func holdsMustBeHeldToTheEnd() {
        var judge = RhythmJudge(notes: [note(1, hold: 1), note(3, lane: 2, hold: 1)])
        _ = judge.press(lane: 0, at: 1)
        #expect(judge.release(lane: 0, at: 1.95) == [.held(note: 0)])
        _ = judge.press(lane: 2, at: 3)
        #expect(judge.release(lane: 2, at: 3.4) == [.broke(note: 1)])
        #expect(judge.combo == 0)
        // Held past the end without letting go yet: done when the song gets there.
        var still = RhythmJudge(notes: [note(1, hold: 1)])
        _ = still.press(lane: 0, at: 1)
        #expect(still.advance(to: 2.4) == [.held(note: 0)])
    }

    @Test func aLostReleaseDoesNotSwallowTheHold() {
        var judge = RhythmJudge(notes: [note(1, hold: 1), note(2.2, hold: 1)])
        _ = judge.press(lane: 0, at: 1)
        // The release after the first hold never arrived; the next press settles it first.
        #expect(judge.press(lane: 0, at: 2.2) == [.held(note: 0), .judged(note: 1, .perfect)])
        #expect(judge.holding[0] == 1)
    }

    @Test func missingTooMuchFailsAndPlayingFinishes() {
        var judge = RhythmJudge(notes: (0..<20).map { note(Double($0)) })
        let events = judge.advance(to: 100)
        #expect(events.last == .failed && judge.failed && judge.grade == "F")
        #expect(judge.advance(to: 200).isEmpty)

        var good = RhythmJudge(notes: [note(1), note(2)])
        _ = good.press(lane: 0, at: 1)
        _ = good.press(lane: 0, at: 2)
        #expect(good.advance(to: 4) == [.finished])
        #expect(good.grade == "S" && good.accuracy == 1)
    }

    @Test func clocksAndCalibration() {
        // Their clock is 100 s ahead; the quickest round trip wins.
        let offset = RhythmJudge.clockOffset([(sent: 0, theirs: 100.2, received: 0.3), (sent: 1, theirs: 101.01, received: 1.02)])
        #expect(abs(offset! - 100) < 0.001)
        let clicks = [10.0, 10.6, 11.2, 11.8]
        #expect(abs(RhythmJudge.calibration(taps: [10.2, 10.79, 11.41, 12.0], clicks: clicks)! - 0.2) < 0.011)
        #expect(RhythmJudge.calibration(taps: [10.0, 10.6], clicks: clicks) == nil, "too few taps")
        #expect(RhythmJudge.calibration(taps: [9.9, 10.5, 11.1, 11.7], clicks: clicks) == 0, "never negative")
    }
}
