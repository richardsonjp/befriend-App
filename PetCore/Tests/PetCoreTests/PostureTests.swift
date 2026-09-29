import Foundation
import Testing
@testable import PetCore

struct PostureTests {
    let baseline = PosturePose(headRise: 1.0, shoulderWidth: 0.30, tilt: 0.02)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func pose(headRise: Double = 1.0, width: Double = 0.30, tilt: Double = 0.02) -> PostureReading {
        .pose(PosturePose(headRise: headRise, shoulderWidth: width, tilt: tilt))
    }

    @Test func judgesAgainstTheCalibration() {
        #expect(PostureScore.judge(pose(), baseline: baseline) == .good)
        #expect(PostureScore.judge(pose(headRise: 0.9, width: 0.33), baseline: baseline) == .good, "small shifts are fine")
        #expect(PostureScore.judge(pose(headRise: 0.7), baseline: baseline) == .slouching, "head sunk into the shoulders")
        #expect(PostureScore.judge(pose(width: 0.40), baseline: baseline) == .slouching, "leaning in to the screen")
        #expect(PostureScore.judge(pose(tilt: 0.3), baseline: baseline) == .slouching, "leaning to one side")
        #expect(PostureScore.judge(.nobody, baseline: baseline) == .nobody)
        #expect(PostureScore.judge(.partial, baseline: baseline) == .nobody)
    }

    @Test func spotsACameraThatMoved() {
        #expect(!PostureScore.implausible(pose(headRise: 0.7), baseline: baseline), "a slouch is still plausible")
        #expect(PostureScore.implausible(pose(headRise: 0.2), baseline: baseline))
        #expect(PostureScore.implausible(pose(width: 0.9), baseline: baseline))
        #expect(PostureScore.implausible(.partial, baseline: baseline), "shoulders out of frame")
        #expect(!PostureScore.implausible(.nobody, baseline: baseline), "walking away isn't a moved camera")
    }

    @Test func redOnlyAfterASustainedSlouchAndGreenAtOnce() {
        var tracker = PostureTracker()
        _ = tracker.observe(.slouching, implausible: false, at: t0)
        _ = tracker.observe(.slouching, implausible: false, at: t0 + 4)
        #expect(tracker.shown != .slouching, "a brief lean doesn't flicker red")
        _ = tracker.observe(.slouching, implausible: false, at: t0 + 5)
        #expect(tracker.shown == .slouching)
        _ = tracker.observe(.good, implausible: false, at: t0 + 6)
        #expect(tracker.shown == .good)
        _ = tracker.observe(.slouching, implausible: false, at: t0 + 7)
        #expect(tracker.shown == .good, "the 5 seconds start over")
    }

    @Test func nudgesAfterAMinuteAtMostEveryTenMinutes() {
        var tracker = PostureTracker()
        var nudges: [TimeInterval] = []
        for second in stride(from: 0.0, through: 1300, by: 1) {
            if tracker.observe(.slouching, implausible: false, at: t0 + second) { nudges.append(second) }
        }
        #expect(nudges == [60, 660, 1260])
    }

    @Test func suggestsRecalibratingWhenTheCameraSeemsMoved() {
        var tracker = PostureTracker()
        _ = tracker.observe(.nobody, implausible: true, at: t0)
        _ = tracker.observe(.nobody, implausible: true, at: t0 + 179)
        #expect(!tracker.needsRecalibration)
        _ = tracker.observe(.nobody, implausible: true, at: t0 + 180)
        #expect(tracker.needsRecalibration)
        _ = tracker.observe(.good, implausible: false, at: t0 + 181)
        #expect(!tracker.needsRecalibration, "a normal pose clears it")
    }

    @Test func aCheckerNeedsACalibrationBeforeItTurnsOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "posture-\(UUID().uuidString)"))
        let checker = PostureChecker(camera: TimelapseCamera(), defaults: defaults)
        checker.setOn(true)
        #expect(!checker.isOn && checker.baseline == nil, "the app shows the calibration sheet instead")
    }
}
