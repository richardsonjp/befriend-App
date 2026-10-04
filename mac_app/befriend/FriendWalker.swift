//
//  FriendWalker.swift
//  befriend
//

import AppKit
import Observation
import PetCore
import SwiftUI

/// Moves the friend around the Mac (M7). It walks into befriend's menu bar icon when it leaves for the iPhone, pops
/// back out of the icon, and every few minutes wanders somewhere else on its display. With Reduce Motion on it only
/// fades in and out where it stands.
@Observable
final class FriendWalker {
    enum Place {
        case inside, hoppingOut, out, wandering, walkingHome, hoppingIn
    }

    private static let tickInterval: TimeInterval = 1.0 / 60
    private static let hopDuration: TimeInterval = 0.5
    private static let fadeDuration: TimeInterval = 0.3
    private static let busyRetry: TimeInterval = 30
    private static let character = CGSize(width: CharacterView.size, height: CharacterView.size)

    /// `PET_WANDER_SECONDS` replaces the 3–8 minute wait between wanders, for testing.
    private static let configuredWanderDelay: TimeInterval? = ProcessInfo.processInfo.environment["PET_WANDER_SECONDS"]
        .flatMap(TimeInterval.init)
        .flatMap { $0 > 0 ? $0 : nil }

    private(set) var place: Place = .inside
    private(set) var facingLeft = false
    /// 0 while tucked into the icon, 1 at full size.
    private(set) var hop: CGFloat = 0

    var isInside: Bool { place == .inside }
    var isWalking: Bool { place == .wandering || place == .walkingHome }
    var isHopping: Bool { place == .hoppingOut || place == .hoppingIn }

    @ObservationIgnored weak var panel: PetPanel?
    /// The menu bar icon's frame on screen, if it has one.
    @ObservationIgnored var dockFrame: () -> CGRect? = { nil }
    /// Whether the friend is free to wander: not talking, reacting or holding a pose.
    @ObservationIgnored var canWander: () -> Bool = { true }
    /// The friend is out and standing still again; reactions held during the walk can play.
    @ObservationIgnored var onSettled: () -> Void = {}

    @ObservationIgnored private var walk: Walk?
    @ObservationIgnored private var walkTimer: Timer?
    @ObservationIgnored private var wanderTask: Task<Void, Never>?
    /// Bumped by every move; animation completions from an older move are ignored.
    @ObservationIgnored private var generation = 0

    private struct Walk {
        var start: CGPoint
        let target: CGPoint
        var startedAt: Date
        var duration: TimeInterval
        var lastOrigin: CGPoint
        let arrive: () -> Void
    }

    // MARK: Commands

    /// The friend belongs on the Mac: pops out of the icon, or turns around if it was on its way in.
    func comeOut() {
        guard let panel else { return }
        switch place {
        case .out, .wandering, .hoppingOut:
            return
        case .walkingHome:
            wanderAway()
        case .hoppingIn:
            animateHop(to:1, as: .hoppingOut) { [weak self] in self?.wanderAway() }
        case .inside:
            guard !Self.reduceMotion, let icon = dockFrame(),
                  let screen = NSScreen.screens.first(where: { $0.frame.intersects(icon) }) else { return fadeIn() }
            stopMoving()
            panel.setFrameOrigin(FriendPaths.dockApproach(icon: icon, visible: screen.visibleFrame, frameSize: panel.frame.size, character: Self.character))
            hop = 0
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            animateHop(to:1, as: .hoppingOut) { [weak self] in self?.wanderAway() }
        }
    }

    /// The friend leaves the Mac: walks into the icon, or vanishes at once when nobody can see it walk (`instant`).
    func goHome(instant: Bool) {
        guard let panel, place != .inside else { return }
        if instant { return settleInside() }
        if Self.reduceMotion { return fadeOut() }
        switch place {
        case .inside, .walkingHome, .hoppingIn:
            return
        case .hoppingOut: // still at the icon
            animateHop(to:0, as: .hoppingIn) { [weak self] in self?.settleInside() }
        case .out, .wandering:
            guard let icon = dockFrame(), let visible = panel.characterScreen?.visibleFrame else { return fadeOut() }
            let target = FriendPaths.dockApproach(icon: icon, visible: visible, frameSize: panel.frame.size, character: Self.character)
            startWalk(to: target, as: .walkingHome) { [weak self] in
                self?.animateHop(to:0, as: .hoppingIn) { self?.settleInside() }
            }
        }
    }

    /// Walks over to stand beside something on screen (the explain card, M31), if it's out.
    func visit(beside box: CGRect) {
        guard let panel, place == .out || place == .wandering, !Self.reduceMotion,
              let visible = panel.characterScreen?.visibleFrame else { return }
        let size = panel.frame.size
        // ponytail: stands left of the box with its feet on the box's bottom edge; right if there's no room.
        let left = box.minX - size.width * 0.75
        let x = left >= visible.minX ? left : min(box.maxX - size.width * 0.25, visible.maxX - size.width)
        let y = min(max(box.minY, visible.minY), visible.maxY - size.height)
        startWalk(to: CGPoint(x: x, y: y), as: .wandering) { [weak self] in self?.settleOut() }
    }

    /// Debug: wander right away instead of after the wait.
    func wanderNow() {
        if place == .out { wanderAway() }
    }

    // MARK: Walking

    private func wanderAway() {
        guard let panel, let visible = panel.characterScreen?.visibleFrame else { return settleOut() }
        var generator = SystemRandomNumberGenerator()
        let target = FriendPaths.wanderTarget(for: panel.frame, in: visible, using: &generator)
        startWalk(to: target, as: .wandering) { [weak self] in self?.settleOut() }
    }

    private func startWalk(to target: CGPoint, as kind: Place, arrive: @escaping () -> Void) {
        guard let panel else { return }
        stopMoving()
        let origin = panel.frame.origin
        walk = Walk(start: origin, target: target, startedAt: .now, duration: FriendPaths.duration(from: origin, to: target), lastOrigin: origin, arrive: arrive)
        place = kind
        facingLeft = target.x < origin.x
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps walking while a menu is open
        walkTimer = timer
    }

    private func step() {
        guard let panel, var walk else { return }
        let origin = panel.frame.origin
        // Held or dragged: a wander stops where it's dropped; a walk home carries on from there once let go.
        if origin != walk.lastOrigin || (NSEvent.pressedMouseButtons != 0 && panel.isMouseOverFriend) {
            guard place == .walkingHome else { return settleOut() }
            walk.start = origin
            walk.lastOrigin = origin
            walk.startedAt = .now
            walk.duration = FriendPaths.duration(from: origin, to: walk.target)
            facingLeft = walk.target.x < origin.x
            self.walk = walk
            return
        }

        let progress = walk.duration > 0 ? min(Date.now.timeIntervalSince(walk.startedAt) / walk.duration, 1) : 1
        panel.setFrameOrigin(CGPoint(
            x: walk.start.x + (walk.target.x - walk.start.x) * progress,
            y: walk.start.y + (walk.target.y - walk.start.y) * progress
        ))
        self.walk?.lastOrigin = panel.frame.origin // read back: AppKit may round to the pixel grid
        panel.updateClickThrough()
        if progress >= 1 {
            stopMoving()
            walk.arrive()
        }
    }

    // MARK: Hops, fades, settling

    private func animateHop(to value: CGFloat, as kind: Place, then done: @escaping () -> Void) {
        stopMoving()
        place = kind
        let move = generation
        withAnimation(.easeInOut(duration: Self.hopDuration)) {
            hop = value
        } completion: { [weak self] in
            guard let self, self.generation == move else { return }
            done()
        }
    }

    private func settleOut() {
        stopMoving()
        place = .out
        onSettled()
        scheduleWander(after: Self.configuredWanderDelay ?? .random(in: FriendPaths.wanderDelays))
    }

    private func settleInside() {
        stopMoving()
        place = .inside
        hop = 0
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    private func scheduleWander(after delay: TimeInterval) {
        wanderTask?.cancel()
        wanderTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.place == .out, !Self.reduceMotion else { return }
            if self.canWander() {
                self.wanderAway()
            } else {
                self.scheduleWander(after: Self.busyRetry)
            }
        }
    }

    private func fadeIn() {
        guard let panel else { return }
        stopMoving()
        // Fading in under the menu bar would cut the bubble off: stand where the pre-walking friend did.
        if !panel.fitsOnScreen { panel.placeBottomRight() }
        hop = 1
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
        settleOut()
    }

    private func fadeOut() {
        guard let panel else { return }
        stopMoving()
        place = .inside
        let move = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == move else { return }
                self.settleInside()
            }
        })
    }

    private func stopMoving() {
        generation += 1
        walkTimer?.invalidate()
        walkTimer = nil
        walk = nil
        wanderTask?.cancel()
        wanderTask = nil
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
