import Foundation
import Testing
@testable import PetCore

struct PomodoroTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let minute: TimeInterval = 60

    @Test func runsAFocusThenWaitsForTheBreak() {
        let started = Pomodoro().start(at: t0)
        #expect(started.status == .running)
        #expect(started.phase == .focus && started.round == 1)
        #expect(started.remaining(at: t0 + 10 * minute) == 15 * minute)
        #expect(started.friendHome, "the friend stays home during focus by default")

        let (after, ended) = started.settle(at: t0 + 26 * minute)
        #expect(ended == [.focus])
        #expect(after.phase == .shortBreak && after.status == .ready)
        #expect(after.completedToday(at: t0 + 26 * minute) == 1)
        #expect(!after.friendHome)
    }

    @Test func pauseAndResumeKeepTheRemainingTime() {
        let paused = Pomodoro().start(at: t0).pause(at: t0 + 5 * minute)
        #expect(paused.status == .paused)
        #expect(paused.remaining(at: t0 + 60 * minute) == 20 * minute)
        #expect(paused.friendHome, "pausing keeps the friend where it is")
        #expect(paused.settle(at: t0 + 60 * minute).ended.isEmpty, "a paused phase never ends")

        let resumed = paused.resume(at: t0 + 60 * minute)
        #expect(resumed.remaining(at: t0 + 60 * minute) == 20 * minute)
        #expect(resumed.settle(at: t0 + 80 * minute).ended == [.focus])
    }

    @Test func everyFourthFocusEarnsALongBreak() {
        var pomodoro = Pomodoro(settings: .init(autoStart: true))
        pomodoro = pomodoro.start(at: t0)
        // 4 focus rounds and 3 short breaks: 4 × 25 + 3 × 5 = 115 minutes
        let (after, ended) = pomodoro.settle(at: t0 + 115 * minute + 1)
        #expect(ended == [.focus, .shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus])
        #expect(after.phase == .longBreak && after.status == .running)
        #expect(after.remaining(at: t0 + 115 * minute) == 15 * minute, "auto-start chains from the real phase end")
        #expect(after.completedToday(at: t0 + 116 * minute) == 4)

        let (next, _) = after.settle(at: t0 + 131 * minute)
        #expect(next.phase == .focus && next.round == 1)
    }

    @Test func skipMovesOnWithoutCountingTheRound() {
        let skipped = Pomodoro().start(at: t0).skip(at: t0 + minute)
        #expect(skipped.phase == .shortBreak && skipped.status == .ready)
        #expect(skipped.completedToday(at: t0 + minute) == 0)

        let back = skipped.skip(at: t0 + 2 * minute)
        #expect(back.phase == .focus && back.round == 2)

        let autoSkipped = Pomodoro(settings: .init(autoStart: true)).skip(at: t0)
        #expect(autoSkipped.status == .running, "auto-start starts the skipped-to phase")
    }

    @Test func resetStartsOverButKeepsTodaysCount() {
        let (done, _) = Pomodoro().start(at: t0).settle(at: t0 + 30 * minute)
        let reset = done.start(at: t0 + 30 * minute).reset()
        #expect(reset.phase == .focus && reset.round == 1 && reset.status == .ready)
        #expect(reset.completedToday(at: t0 + 31 * minute) == 1)
    }

    @Test func letOutLastsUntilThePhaseChanges() {
        let out = Pomodoro(settings: .init(autoStart: true)).start(at: t0).letFriendOut()
        #expect(!out.friendHome)
        let (nextFocus, _) = out.settle(at: t0 + 31 * minute)
        #expect(nextFocus.phase == .focus && nextFocus.friendHome)

        let stayOut = Pomodoro(settings: .init(friendStaysHome: false)).start(at: t0)
        #expect(!stayOut.friendHome)
    }

    @Test func todaysCountStartsOverOnANewDay() {
        let (done, _) = Pomodoro().start(at: t0).settle(at: t0 + 30 * minute)
        #expect(done.completedToday(at: t0 + 30 * minute) == 1)
        #expect(done.completedToday(at: t0 + 2 * 86_400) == 0)
    }

    @Test func settingsAreClampedAndSurviveARoundTrip() throws {
        let odd = PomodoroSettings(focus: 0, shortBreak: -5, longBreak: 99_999, longBreakEvery: 0)
        #expect(odd.focus == 60 && odd.shortBreak == 60 && odd.longBreak == 180 * 60 && odd.longBreakEvery == 1)

        // a stored blob with out-of-range values decodes clamped, not as written
        var raw = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(odd)) as? [String: Any])
        raw["longBreakEvery"] = 0
        raw["focus"] = -1
        let stored = try JSONDecoder().decode(PomodoroSettings.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(stored.longBreakEvery == 1 && stored.focus == 60)

        let running = Pomodoro(settings: .init(focus: 50 * 60)).start(at: t0)
        let decoded = try JSONDecoder().decode(Pomodoro.self, from: JSONEncoder().encode(running))
        #expect(decoded == running)
    }
}
