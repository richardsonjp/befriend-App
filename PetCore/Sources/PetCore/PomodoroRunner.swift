//
//  PomodoroRunner.swift
//  PetCore
//

import Foundation
import Observation

/// Runs a device's focus timer (M10): applies the user's commands, ticks once a second while a focus runs, settles
/// it when it ends and saves every change. The app decides what the end sounds like and what the friend does.
@Observable
public final class PomodoroRunner {
    public private(set) var state: Pomodoro
    /// Refreshed every second while a focus runs, so countdowns redraw.
    public private(set) var now = Date.now

    /// After every change: the countdown, the status, or whether the friend should be home.
    @ObservationIgnored public var onChange: () -> Void = {}
    /// A focus ran to 0:00 while the app was running (catch-ups at launch are silent).
    @ObservationIgnored public var onFocusEnded: (_ after: Pomodoro) -> Void = { _ in }
    /// Something the friend reacts to: a focus starting or ending, being let out. Called before `onChange`.
    @ObservationIgnored public var onMoment: (PomodoroMoment) -> Void = { _ in }

    @ObservationIgnored private let save: (Pomodoro) -> Void
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// A focus that ended while the app was quit is caught up silently: announcing it now would be old news.
    public init(saved: Pomodoro?, save: @escaping (Pomodoro) -> Void) {
        self.save = save
        state = (saved ?? Pomodoro()).settle(at: .now).pomodoro
        if state.status == .running { startTicking() }
    }

    public func start() { change { $0.start(at: .now) } }
    public func pause() { change { $0.pause(at: .now) } }
    public func stop() { change { $0.stop() } }
    public func letFriendOut() { change { $0.letFriendOut() } }
    public func update(_ settings: PomodoroSettings) { change { $0.with(settings: settings) } }

    /// Catches up now, e.g. when the app comes back to the foreground.
    public func settle() {
        now = .now
        let (next, ended) = state.settle(at: now)
        guard ended else { return }
        change(ended: true) { _ in next }
        onFocusEnded(next)
    }

    private func change(ended: Bool = false, _ edit: (Pomodoro) -> Pomodoro) {
        let before = state
        state = edit(state)
        now = .now
        save(state)
        ticker?.cancel()
        ticker = nil
        if state.status == .running { startTicking() }
        if let moment = Pomodoro.moment(from: before, to: state, ended: ended) { onMoment(moment) }
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
}
