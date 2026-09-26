//
//  Pomodoro.swift
//  PetCore
//
//  The pomodoro timer (M10). Each device runs its own; nothing is synced. It stores when the phase ends rather than
//  ticking, so it survives sleep and relaunches: every change takes `now` and returns a new value, and `settle`
//  catches up on phases that ended while nobody was looking. Callers settle before reading `status` or
//  `friendHome`: until then a phase whose time is up still reads as running.
//

import Foundation

public nonisolated enum PomodoroPhase: String, Codable, Sendable {
    case focus, shortBreak, longBreak

    public var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }
}

public nonisolated enum PomodoroStatus: Sendable {
    /// The phase hasn't started (a new session, or a finished phase waiting for the user).
    case ready
    case running
    case paused
}

public nonisolated struct PomodoroSettings: Codable, Equatable, Sendable {
    public static let durations: ClosedRange<TimeInterval> = 60...(180 * 60)
    public static let rounds = 1...12

    public let focus: TimeInterval
    public let shortBreak: TimeInterval
    public let longBreak: TimeInterval
    /// A long break follows every this many focus rounds.
    public let longBreakEvery: Int
    /// Starts the next phase as soon as one ends.
    public let autoStart: Bool
    public let sound: Bool
    /// The friend goes home (Mac) or focuses alongside you (iPhone) during focus.
    public let friendStaysHome: Bool

    public init(focus: TimeInterval = 25 * 60, shortBreak: TimeInterval = 5 * 60, longBreak: TimeInterval = 15 * 60,
                longBreakEvery: Int = 4, autoStart: Bool = false, sound: Bool = true, friendStaysHome: Bool = true) {
        self.focus = focus.clamped(to: Self.durations)
        self.shortBreak = shortBreak.clamped(to: Self.durations)
        self.longBreak = longBreak.clamped(to: Self.durations)
        self.longBreakEvery = longBreakEvery.clamped(to: Self.rounds)
        self.autoStart = autoStart
        self.sound = sound
        self.friendStaysHome = friendStaysHome
    }

    /// Stored settings go through the same clamps: a longBreakEvery of 0 would divide by zero.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(focus: try c.decode(TimeInterval.self, forKey: .focus),
                  shortBreak: try c.decode(TimeInterval.self, forKey: .shortBreak),
                  longBreak: try c.decode(TimeInterval.self, forKey: .longBreak),
                  longBreakEvery: try c.decode(Int.self, forKey: .longBreakEvery),
                  autoStart: try c.decode(Bool.self, forKey: .autoStart),
                  sound: try c.decode(Bool.self, forKey: .sound),
                  friendStaysHome: try c.decode(Bool.self, forKey: .friendStaysHome))
    }

    /// A copy with some settings changed, clamped like any other.
    public func with(focus: TimeInterval? = nil, shortBreak: TimeInterval? = nil, longBreak: TimeInterval? = nil,
                     longBreakEvery: Int? = nil, autoStart: Bool? = nil, sound: Bool? = nil,
                     friendStaysHome: Bool? = nil) -> PomodoroSettings {
        PomodoroSettings(focus: focus ?? self.focus, shortBreak: shortBreak ?? self.shortBreak,
                         longBreak: longBreak ?? self.longBreak, longBreakEvery: longBreakEvery ?? self.longBreakEvery,
                         autoStart: autoStart ?? self.autoStart, sound: sound ?? self.sound,
                         friendStaysHome: friendStaysHome ?? self.friendStaysHome)
    }

    public func duration(_ phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }
}

public nonisolated struct Pomodoro: Codable, Equatable, Sendable {
    public private(set) var settings: PomodoroSettings
    public private(set) var phase = PomodoroPhase.focus
    /// The focus round within the cycle, 1...longBreakEvery.
    public private(set) var round = 1
    /// When the running phase ends; nil while ready or paused.
    public private(set) var endsAt: Date?
    private var pausedRemaining: TimeInterval?
    private var friendLetOut = false
    private var completed = 0
    private var completedDay: Date?

    /// A catch-up after a very long sleep with auto-start stops here and leaves the rest for the next settle.
    private static let maxPhasesPerSettle = 100

    public init(settings: PomodoroSettings = PomodoroSettings()) {
        self.settings = settings
    }

    public var status: PomodoroStatus {
        if endsAt != nil { return .running }
        return pausedRemaining == nil ? .ready : .paused
    }

    /// "18:42"; minutes run past 60 for long settings.
    public static func clock(_ remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    public func remaining(at now: Date) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return pausedRemaining ?? settings.duration(phase)
    }

    /// Focus rounds finished today (skipped ones don't count).
    public func completedToday(at now: Date) -> Int {
        completedDay == Calendar.current.startOfDay(for: now) ? completed : 0
    }

    /// Whether the friend should be home: a started focus phase, unless the user let it out or turned it off.
    public var friendHome: Bool {
        settings.friendStaysHome && phase == .focus && status != .ready && !friendLetOut
    }

    /// What the friend should know while the user focuses with it out, for the model's prompt; nil otherwise.
    public func promptContext(at now: Date) -> String? {
        guard phase == .focus, status == .running, !friendHome else { return nil }
        let minutes = max(1, Int((remaining(at: now) / 60).rounded(.up)))
        return "The user is in a focus session with \(minutes) minutes left: keep it short and encouraging."
    }

    /// The moment a change amounts to, if any: a phase that ended, a focus phase starting (not resuming), or the
    /// friend being let out mid-focus. A catch-up over several phases passes only the last one: the friend reacts to
    /// where the user is now. Skipping and settings changes aren't moments.
    public static func moment(from before: Pomodoro, to after: Pomodoro, ended: PomodoroPhase?) -> PomodoroMoment? {
        if let ended {
            return ended == .focus ? .focusEnded(longBreak: after.phase == .longBreak) : .breakEnded
        }
        let resumed = before.phase == .focus && before.round == after.round && before.status != .ready
        if after.phase == .focus, after.status == .running, !resumed {
            return .focusStarted(minutes: Int(after.settings.focus / 60))
        }
        if before.friendHome, !after.friendHome, after.phase == .focus, after.status != .ready,
           before.settings == after.settings {
            return .calledOut
        }
        return nil
    }

    public func with(settings: PomodoroSettings) -> Pomodoro {
        var copy = self
        copy.settings = settings
        return copy
    }

    public func start(at now: Date) -> Pomodoro {
        switch status {
        case .running: return self
        case .paused: return resume(at: now)
        case .ready:
            var copy = self
            copy.endsAt = now + settings.duration(phase)
            return copy
        }
    }

    public func pause(at now: Date) -> Pomodoro {
        guard let endsAt else { return self }
        var copy = self
        copy.pausedRemaining = max(0, endsAt.timeIntervalSince(now))
        copy.endsAt = nil
        return copy
    }

    public func resume(at now: Date) -> Pomodoro {
        guard let pausedRemaining else { return self }
        var copy = self
        copy.endsAt = now + pausedRemaining
        copy.pausedRemaining = nil
        return copy
    }

    /// Moves to the next phase without counting this one; auto-start starts it.
    public func skip(at now: Date) -> Pomodoro {
        let next = advanced(completedAt: nil)
        return settings.autoStart ? next.start(at: now) : next
    }

    /// Back to the first focus round, stopped. Today's count stays.
    public func reset() -> Pomodoro {
        var copy = self
        copy.phase = .focus
        copy.round = 1
        copy.endsAt = nil
        copy.pausedRemaining = nil
        copy.friendLetOut = false
        return copy
    }

    public func letFriendOut() -> Pomodoro {
        var copy = self
        copy.friendLetOut = true
        return copy
    }

    /// Ends every phase whose time is up, in order. Auto-start chains each next phase from the moment the previous
    /// one ended, so a Mac waking from sleep lands on the phase the user would be in now. `autoStart: false` stops at
    /// the first phase end regardless of the setting (the iPhone, catching up after being suspended).
    public func settle(at now: Date, autoStart: Bool = true) -> (pomodoro: Pomodoro, ended: [PomodoroPhase]) {
        var current = self
        var ended: [PomodoroPhase] = []
        while let end = current.endsAt, end <= now, ended.count < Self.maxPhasesPerSettle {
            ended.append(current.phase)
            current = current.advanced(completedAt: end)
            if autoStart, current.settings.autoStart {
                current.endsAt = end + current.settings.duration(current.phase)
            }
        }
        return (current, ended)
    }

    /// The next phase, not started. `completedAt` counts a finished focus round toward that day.
    private func advanced(completedAt: Date?) -> Pomodoro {
        var copy = self
        if phase == .focus, let completedAt {
            let day = Calendar.current.startOfDay(for: completedAt)
            copy.completed = (completedDay == day ? completed : 0) + 1
            copy.completedDay = day
        }
        switch phase {
        case .focus:
            copy.phase = round % settings.longBreakEvery == 0 ? .longBreak : .shortBreak
        case .shortBreak:
            copy.phase = .focus
            copy.round = round + 1
        case .longBreak:
            copy.phase = .focus
            copy.round = 1
        }
        copy.endsAt = nil
        copy.pausedRemaining = nil
        copy.friendLetOut = false
        return copy
    }
}

private extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
