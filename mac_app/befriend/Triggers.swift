//
//  Triggers.swift
//  befriend
//

import AppKit
import CoreGraphics
import PetCore

/// Watches app switches (NSWorkspace) and system-wide idle time, and reports them as triggers; after every
/// `encourageEvery` of active use (input within the last minute), an `.encourage` trigger (M17).
final class TriggerMonitor {
    /// Short poll so "welcome back" lands within a couple of seconds; the idle read itself is a cheap syscall.
    static let pollInterval: TimeInterval = 2
    private static let defaultIdleThreshold: TimeInterval = 5 * 60
    private static let anyInputEvent = CGEventType(rawValue: ~0)! // kCGAnyInputEventType
    private static let defaultEncourageEvery: TimeInterval = 30 * 60
    /// Input within this long counts as using the Mac.
    private static let activeWindow: TimeInterval = 60

    /// `PET_IDLE_SECONDS` overrides the idle threshold for testing.
    static var configuredIdleThreshold: TimeInterval {
        ProcessInfo.processInfo.environment["PET_IDLE_SECONDS"]
            .flatMap(TimeInterval.init)
            .flatMap { $0 > 0 ? $0 : nil } ?? defaultIdleThreshold
    }

    /// `PET_ENCOURAGE_SECONDS` overrides the active time between encouragements for testing.
    static var configuredEncourageEvery: TimeInterval {
        ProcessInfo.processInfo.environment["PET_ENCOURAGE_SECONDS"]
            .flatMap(TimeInterval.init)
            .flatMap { $0 > 0 ? $0 : nil } ?? defaultEncourageEvery
    }

    private let idleThreshold: TimeInterval
    private let encourageEvery = TriggerMonitor.configuredEncourageEvery
    private var activeSeconds: TimeInterval = 0
    private let onIdleReading: (TimeInterval) -> Void
    private let onTrigger: (Trigger) -> Void
    private var idleStart: Date?
    private var appObserver: NSObjectProtocol?
    private var idleTimer: Timer?

    /// `onIdleReading` gets every idle poll (seconds since the last input), e.g. for presence.
    init(
        idleThreshold: TimeInterval = TriggerMonitor.configuredIdleThreshold,
        onIdleReading: @escaping (TimeInterval) -> Void = { _ in },
        onTrigger: @escaping (Trigger) -> Void
    ) {
        self.idleThreshold = idleThreshold
        self.onIdleReading = onIdleReading
        self.onTrigger = onTrigger
    }

    func stop() {
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        idleTimer?.invalidate()
        idleTimer = nil
        idleStart = nil
        activeSeconds = 0
    }

    func start() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPID else { return }
            let name = app.localizedName ?? ""
            MainActor.assumeIsolated { self?.onTrigger(.appSwitched(name: name)) }
        }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInputEvent)
            MainActor.assumeIsolated {
                self?.onIdleReading(idle)
                self?.update(idleSeconds: idle)
                self?.countActive(idleSeconds: idle)
            }
        }
        timer.tolerance = Self.pollInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// Adds a poll's worth of active time, and encourages once enough has added up.
    func countActive(idleSeconds: TimeInterval, elapsed: TimeInterval = TriggerMonitor.pollInterval) {
        guard idleSeconds < Self.activeWindow else { return }
        activeSeconds += elapsed
        guard activeSeconds >= encourageEvery else { return }
        activeSeconds = 0
        onTrigger(.encourage)
    }

    /// Feeds one idle reading through the active ⇄ idle transition.
    func update(idleSeconds: TimeInterval, now: Date = .now) {
        if let idleStart {
            guard idleSeconds < idleThreshold else { return }
            self.idleStart = nil
            onTrigger(.returned(afterSeconds: now.timeIntervalSince(idleStart) - idleSeconds))
        } else if idleSeconds >= idleThreshold {
            idleStart = now.addingTimeInterval(-idleSeconds)
            onTrigger(.wentIdle(seconds: idleSeconds))
        }
    }
}
