//
//  FriendPaths.swift
//  PetCore
//
//  Where the Mac friend walks (M7). Screen points with AppKit's bottom-left origin. A "frame" is the friend's
//  window: the character stands at its bottom centre, with the speech bubble's room above it.
//

import CoreGraphics
import Foundation

public nonisolated enum FriendPaths {
    /// Points per second.
    public static let walkSpeed: CGFloat = 140
    /// A wander should look like a trip, not a shuffle.
    public static let minimumWander: CGFloat = 200
    /// How long the friend stays put between wanders.
    public static let wanderDelays: ClosedRange<TimeInterval> = 180...480

    /// A random origin for `frame` where the whole window (bubble room included) fits on `visible`, at least
    /// `minimumWander` from where it is. On a display too small for that, the farthest of the tries.
    public static func wanderTarget(for frame: CGRect, in visible: CGRect, using generator: inout some RandomNumberGenerator) -> CGPoint {
        let xs = visible.minX...max(visible.minX, visible.maxX - frame.width)
        let ys = visible.minY...max(visible.minY, visible.maxY - frame.height)
        var farthest = frame.origin
        for _ in 0..<8 {
            let candidate = CGPoint(x: .random(in: xs, using: &generator), y: .random(in: ys, using: &generator))
            if distance(frame.origin, candidate) >= minimumWander { return candidate }
            if distance(frame.origin, candidate) > distance(frame.origin, farthest) { farthest = candidate }
        }
        return farthest
    }

    /// The window origin that stands the character (at the window's bottom centre) just under the menu bar, below
    /// `icon`. Clamped to `visible`, so a friend on another display walks to its own top edge and never crosses over.
    public static func dockApproach(icon: CGRect, visible: CGRect, frameSize: CGSize, character: CGSize) -> CGPoint {
        let centerX = min(max(icon.midX, visible.minX + character.width / 2), visible.maxX - character.width / 2)
        return CGPoint(x: centerX - frameSize.width / 2, y: visible.maxY - character.height)
    }

    /// Seconds to walk in a straight line at `walkSpeed`.
    public static func duration(from start: CGPoint, to end: CGPoint) -> TimeInterval {
        TimeInterval(distance(start, end) / walkSpeed)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}
