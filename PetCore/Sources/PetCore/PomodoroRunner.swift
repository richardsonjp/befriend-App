//
//  PomodoroRunner.swift
//  PetCore
//

import Foundation
import Observation

/// Runs a device's pomodoro (M10): applies the user's commands, ticks once a second while a phase runs, settles
/// phases as they end and saves every change. The app decides what a phase end sounds like and what the friend does.
@Observable
public final class PomodoroRunner {
    public private(set) var state: Pomodoro
    /// Refreshed every second while a phase runs, so countdowns redraw.
    public private(set) var now = Date.now

    /// After every change: the countdown, the phase, or whether the friend should be home.
    @ObservationIgnored public var onChange: () -> Void = {}
    /// A phase ended while the app was running (catch-ups at launch are silent). `next` is the state after it.
    @ObservationIgnored public var onPhaseEnded: (_ ended: PomodoroPhase, _ next: Pomodoro) -> Void = { _, _ in }
    /// Something the friend reacts to: a focus starting, a phase ending, being let out. Called before `onChange`.
    @ObservationIgnored public var onMoment: (PomodoroMoment) -> Void = { _ in }
    /// Whether auto-start may start phases right now (the iPhone: only while the app is open).
    @ObservationIgnored public var mayAutoStart: () -> Bool = { true }

    @ObservationIgnored private let save: (Pomodoro) -> Void
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Phases that ended while the app was quit are caught up silently: announcing them now would be old news.
    public init(saved: Pomodoro?, save: @escaping (Pomodoro) -> Void) {
        self.save = save
        state = (saved ?? Pomodoro()).settle(at: .now, autoStart: false).pomodoro
        if state.status == .running { startTicking() }
    }

    public func start() { change { $0.start(at: .now) } }
    public func pause() { change { $0.pause(at: .now) } }
    public func skip() { change { $0.skip(at: .now) } }
    public func reset() { change { $0.reset() } }
    public func letFriendOut() { change { $0.letFriendOut() } }
    public func update(_ settings: PomodoroSettings) { change { $0.with(settings: settings) } }

    /// Catches up now, e.g. when the app comes back to the foreground.
    public func settle() {
        now = .now
        let (next, ended) = state.settle(at: now, autoStart: mayAutoStart())
        guard let last = ended.last else { return }
        change(ended: last) { _ in next }
        onPhaseEnded(last, next)
    }

    private func change(ended: PomodoroPhase? = nil, _ edit: (Pomodoro) -> Pomodoro) {
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
