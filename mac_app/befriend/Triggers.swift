//
//  Triggers.swift
//  befriend
//

import AppKit
import CoreGraphics
import PetCore

/// Watches app switches (NSWorkspace) and system-wide idle time, and reports them as triggers.
final class TriggerMonitor {
    /// Short poll so "welcome back" lands within a couple of seconds; the idle read itself is a cheap syscall.
    private static let pollInterval: TimeInterval = 2
    private static let defaultIdleThreshold: TimeInterval = 5 * 60
    private static let anyInputEvent = CGEventType(rawValue: ~0)! // kCGAnyInputEventType

    /// `PET_IDLE_SECONDS` overrides the idle threshold for testing.
    static var configuredIdleThreshold: TimeInterval {
        ProcessInfo.processInfo.environment["PET_IDLE_SECONDS"]
            .flatMap(TimeInterval.init)
            .flatMap { $0 > 0 ? $0 : nil } ?? defaultIdleThreshold
    }

    private let idleThreshold: TimeInterval
    private let onTrigger: (Trigger) -> Void
    private var idleStart: Date?
    private var appObserver: NSObjectProtocol?
    private var idleTimer: Timer?

    init(idleThreshold: TimeInterval = TriggerMonitor.configuredIdleThreshold, onTrigger: @escaping (Trigger) -> Void) {
        self.idleThreshold = idleThreshold
        self.onTrigger = onTrigger
    }

    // ponytail: runs for the app's lifetime, so no stop()/teardown.
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
            MainActor.assumeIsolated { self?.update(idleSeconds: idle) }
        }
        timer.tolerance = Self.pollInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
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
