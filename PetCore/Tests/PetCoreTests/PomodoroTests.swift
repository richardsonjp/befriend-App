import Foundation
import Testing
@testable import PetCore

struct PomodoroTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let minute: TimeInterval = 60

    @Test func aFocusRunsToZeroThenWaits() {
        let started = Pomodoro().start(at: t0)
        #expect(started.status == .running)
        #expect(started.remaining(at: t0 + 10 * minute) == 15 * minute)
        #expect(started.friendHome, "the friend stays home during focus by default")

        #expect(!started.settle(at: t0 + 24 * minute).ended)
        let (after, ended) = started.settle(at: t0 + 26 * minute)
        #expect(ended && after.status == .ready)
        #expect(after.remaining(at: t0 + 26 * minute) == 25 * minute, "ready again for the next focus")
        #expect(after.completedToday(at: t0 + 26 * minute) == 1)
        #expect(!after.friendHome)
        #expect(after.phaseID == started.phaseID + 1, "the next focus is a different one")
        #expect(Pomodoro.clock(61 * minute + 0.2) == "61:01")
    }

    @Test func pauseAndResumeKeepTheRemainingTime() {
        let paused = Pomodoro().start(at: t0).pause(at: t0 + 5 * minute)
        #expect(paused.status == .paused)
        #expect(paused.remaining(at: t0 + 60 * minute) == 20 * minute)
        #expect(paused.friendHome, "pausing keeps the friend where it is")
        #expect(!paused.settle(at: t0 + 60 * minute).ended, "a paused focus never ends")

        let resumed = paused.resume(at: t0 + 60 * minute)
        #expect(resumed.remaining(at: t0 + 60 * minute) == 20 * minute)
        #expect(resumed.settle(at: t0 + 80 * minute).ended)
    }

    @Test func stoppingEarlyDoesNotCount() {
        let (done, _) = Pomodoro().start(at: t0).settle(at: t0 + 30 * minute)
        let running = done.start(at: t0 + 30 * minute)
        let stopped = running.stop()
        #expect(stopped.status == .ready && stopped.completedToday(at: t0 + 31 * minute) == 1)
        #expect(stopped.phaseID == running.phaseID + 1)
        #expect(stopped.stop() == stopped, "stopping when nothing runs changes nothing")
    }

    @Test func letOutLastsUntilTheFocusEnds() {
        let out = Pomodoro().start(at: t0).letFriendOut()
        #expect(!out.friendHome)
        let next = out.settle(at: t0 + 26 * minute).pomodoro.start(at: t0 + 27 * minute)
        #expect(next.friendHome)

        let stayOut = Pomodoro(settings: .init(friendStaysHome: false)).start(at: t0)
        #expect(!stayOut.friendHome)
    }

    @Test func todaysCountStartsOverOnANewDay() {
        let (done, _) = Pomodoro().start(at: t0).settle(at: t0 + 30 * minute)
        #expect(done.completedToday(at: t0 + 30 * minute) == 1)
        #expect(done.completedToday(at: t0 + 2 * 86_400) == 0)
    }

    @Test func settingsAreClampedAndSurviveARoundTrip() throws {
        #expect(PomodoroSettings(focus: 0).focus == 60 && PomodoroSettings(focus: 99_999).focus == 180 * 60)

        var raw = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(PomodoroSettings())) as? [String: Any])
        raw["focus"] = -1
        let stored = try JSONDecoder().decode(PomodoroSettings.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(stored.focus == 60, "a stored blob decodes clamped, not as written")

        let edited = PomodoroSettings().with(sound: false)
        #expect(!edited.sound && edited.focus == 25 * 60, "with() changes only what it's given")

        let running = Pomodoro(settings: .init(focus: 50 * 60)).start(at: t0)
        let decoded = try JSONDecoder().decode(Pomodoro.self, from: JSONEncoder().encode(running))
        #expect(decoded == running)
    }

    @Test func aPomodoroSavedWithBreaksStillLoads() throws {
        let old = """
        {"settings":{"focus":1800,"shortBreak":300,"longBreak":900,"longBreakEvery":4,"autoStart":true,"sound":false,
        "friendStaysHome":true},"phase":"shortBreak","round":2,"friendLetOut":false,"completed":3,"phases":5}
        """
        let loaded = try JSONDecoder().decode(Pomodoro.self, from: Data(old.utf8))
        #expect(loaded.settings == PomodoroSettings(focus: 1800, sound: false))
        #expect(loaded.status == .ready && loaded.phaseID == 5)
    }

    @Test func liveActivityShowsOnlyAFocusUnderWay() throws {
        #expect(PomodoroSurface(Pomodoro(), at: t0) == nil, "no timer on the Lock Screen until one starts")
        let running = try #require(PomodoroSurface(Pomodoro().start(at: t0), at: t0 + minute))
        #expect(running.endDate == t0 + 25 * minute && running.remaining == 24 * minute && running.focusing && !running.paused)
        let paused = try #require(PomodoroSurface(Pomodoro().start(at: t0).pause(at: t0 + minute), at: t0 + 2 * minute))
        #expect(paused.endsAt == nil && paused.paused && paused.remaining == 24 * minute)
        #expect(PomodoroSurface(Pomodoro().start(at: t0).stop(), at: t0) == nil, "stopping hides it")
    }

    @Test func momentsTheFriendReactsTo() {
        let ready = Pomodoro()
        let running = ready.start(at: t0)
        #expect(Pomodoro.moment(from: ready, to: running, ended: false) == .focusStarted(minutes: 25))
        let paused = running.pause(at: t0 + minute)
        #expect(Pomodoro.moment(from: running, to: paused, ended: false) == nil)
        #expect(Pomodoro.moment(from: paused, to: paused.start(at: t0 + 2 * minute), ended: false) == nil, "resuming isn't a new start")
        #expect(Pomodoro.moment(from: running, to: running.letFriendOut(), ended: false) == .calledOut)
        let homeOff = running.with(settings: running.settings.with(friendStaysHome: false))
        #expect(Pomodoro.moment(from: running, to: homeOff, ended: false) == nil, "a settings change isn't being let out")
        #expect(Pomodoro.moment(from: running, to: running.stop(), ended: false) == nil, "stopping isn't a moment")

        let (done, _) = running.settle(at: t0 + 26 * minute)
        #expect(Pomodoro.moment(from: running, to: done, ended: true) == .focusEnded)

        #expect(running.promptContext(at: t0 + minute) == nil, "home: the friend isn't talking")
        #expect(running.letFriendOut().promptContext(at: t0 + 10 * minute)?.contains("15 minutes left") == true)
    }
}
