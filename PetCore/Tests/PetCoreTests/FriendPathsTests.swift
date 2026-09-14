import CoreGraphics
import Testing
@testable import PetCore

/// Repeatable randomness (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct FriendPathsTests {
    let window = CGSize(width: 240, height: 200)
    let character = CGSize(width: 64, height: 64)

    @Test func wandersSomewhereTheWholeWindowFits() {
        // a second display left of the main one, below a menu bar
        let visible = CGRect(x: -1920, y: 40, width: 1920, height: 1015)
        for seed in UInt64(0)..<300 {
            var generator = SeededGenerator(state: seed)
            let frame = CGRect(origin: CGPoint(x: -900, y: 400), size: window)
            let target = FriendPaths.wanderTarget(for: frame, in: visible, using: &generator)
            #expect(visible.contains(CGRect(origin: target, size: window)), "seed \(seed): \(target)")
            #expect(hypot(target.x - frame.minX, target.y - frame.minY) >= FriendPaths.minimumWander, "seed \(seed)")
        }
    }

    @Test func aTinyDisplayStillGetsATargetOnIt() {
        var generator = SeededGenerator(state: 7)
        let visible = CGRect(x: 0, y: 0, width: 260, height: 210)
        let frame = CGRect(origin: CGPoint(x: 10, y: 5), size: window)
        let target = FriendPaths.wanderTarget(for: frame, in: visible, using: &generator)
        #expect(visible.contains(CGRect(origin: target, size: window)))
    }

    @Test func walksHomeUnderTheIconOnItsOwnDisplay() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let icon = CGRect(x: 1190, y: 878, width: 22, height: 22)
        #expect(FriendPaths.dockApproach(icon: icon, visible: visible, frameSize: window, character: character)
            == CGPoint(x: 1201 - 120, y: 875 - 64))

        // the icon's menu bar is on the display to the right: stop at this display's top edge
        let elsewhere = icon.offsetBy(dx: 2000, dy: 0)
        #expect(FriendPaths.dockApproach(icon: elsewhere, visible: visible, frameSize: window, character: character)
            == CGPoint(x: 1440 - 32 - 120, y: 875 - 64))
    }

    @Test func walkingTakesDistanceOverSpeed() {
        #expect(FriendPaths.duration(from: .zero, to: CGPoint(x: 54, y: 72)) == 1) // 90 points
    }
}
