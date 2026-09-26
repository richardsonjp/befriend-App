//
//  MacPomodoro.swift
//  befriend
//

import AppKit
import Observation
import PetCore
import UserNotifications

/// The Mac's own pomodoro (M10): runs PetCore's timer, saves it, rings at each phase end, and tells the controller
/// when the friend should go home. Nothing is shared with the iPhone.
@Observable
final class MacPomodoro {
    private(set) var state: Pomodoro
    /// Refreshed every second while a phase runs, so countdowns redraw.
    private(set) var now = Date.now
    /// Whether the friend should be home may have changed.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init() {
        // Phases that ended while the app was quit are caught up silently: announcing them now would be old news.
        state = (MacConfig.loadPomodoro() ?? Pomodoro()).settle(at: .now).pomodoro
        if state.status == .running { startTicking() }
    }

    func start() {
        change { $0.start(at: .now) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } // prompts only once
    }

    func pause() { change { $0.pause(at: .now) } }
    func skip() { change { $0.skip(at: .now) } }
    func reset() { change { $0.reset() } }
    func letFriendOut() { change { $0.letFriendOut() } }
    func update(_ settings: PomodoroSettings) { change { $0.with(settings: settings) } }

    /// "18:42": minutes can pass 60 for long focus settings.
    static func clock(_ remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func title(_ phase: PomodoroPhase) -> String {
        switch phase {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    private func change(_ edit: (Pomodoro) -> Pomodoro) {
        state = edit(state)
        now = .now
        MacConfig.savePomodoro(state)
        ticker?.cancel()
        ticker = nil
        if state.status == .running { startTicking() }
        onChange()
    }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.settle()
            }
        }
    }

    private func settle() {
        now = .now
        let (next, ended) = state.settle(at: now)
        guard let last = ended.last else { return }
        announce(ended: last, next: next)
        change { _ in next }
    }

    private func announce(ended: PomodoroPhase, next: Pomodoro) {
        if next.settings.sound { NSSound(named: "Glass")?.play() }
        let content = UNMutableNotificationContent()
        switch ended {
        case .focus:
            content.title = "Focus done 🍅"
            content.body = next.phase == .longBreak ? "Time for a long break." : "Time for a short break."
        case .shortBreak, .longBreak:
            content.title = "Break's over"
            content.body = next.status == .running ? "Focus started." : "Ready to focus?"
        }
        let request = UNNotificationRequest(identifier: "pomodoro", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in } // ponytail: denied notifications just stay silent
    }
}
