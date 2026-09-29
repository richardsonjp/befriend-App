//
//  Pomodoro.swift
//  PetCore
//
//  The focus timer (M10, one step since M13): set the minutes, start, pause or stop; it ends at 0:00 and waits for
//  the next start. Each device runs its own; nothing is synced. It stores when the focus ends rather than ticking,
//  so it survives sleep and relaunches: every change takes `now` and returns a new value, and `settle` catches up on
//  a focus that ended while nobody was looking. Callers settle before reading `status` or `friendHome`: until then
//  a focus whose time is up still reads as running.
//

import Foundation

public nonisolated enum PomodoroStatus: Sendable {
    /// No focus is under way.
    case ready
    case running
    case paused
}

public nonisolated struct PomodoroSettings: Codable, Equatable, Sendable {
    public static let durations: ClosedRange<TimeInterval> = 60...(180 * 60)

    public let focus: TimeInterval
    public let sound: Bool
    /// The friend goes home (Mac) or focuses alongside you (iPhone) during focus.
    public let friendStaysHome: Bool
    /// Each focus records a 1-minute timelapse with the device's camera (M11).
    public let recordTimelapse: Bool
    /// The timelapse's shape and which part of the camera it keeps (M16).
    public let framing: TimelapseFraming

    public init(focus: TimeInterval = 25 * 60, sound: Bool = true, friendStaysHome: Bool = true, recordTimelapse: Bool = false,
                framing: TimelapseFraming = TimelapseFraming()) {
        self.focus = focus.clamped(to: Self.durations)
        self.sound = sound
        self.friendStaysHome = friendStaysHome
        self.recordTimelapse = recordTimelapse
        self.framing = framing
    }

    /// Stored settings go through the same clamps. Settings saved before M13 carry break keys, which are ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(focus: try c.decode(TimeInterval.self, forKey: .focus),
                  sound: try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true,
                  friendStaysHome: try c.decodeIfPresent(Bool.self, forKey: .friendStaysHome) ?? true,
                  recordTimelapse: try c.decodeIfPresent(Bool.self, forKey: .recordTimelapse) ?? false,
                  framing: try c.decodeIfPresent(TimelapseFraming.self, forKey: .framing) ?? TimelapseFraming())
    }

    /// A copy with some settings changed, clamped like any other.
    public func with(focus: TimeInterval? = nil, sound: Bool? = nil, friendStaysHome: Bool? = nil,
                     recordTimelapse: Bool? = nil, framing: TimelapseFraming? = nil) -> PomodoroSettings {
        PomodoroSettings(focus: focus ?? self.focus, sound: sound ?? self.sound,
                         friendStaysHome: friendStaysHome ?? self.friendStaysHome,
                         recordTimelapse: recordTimelapse ?? self.recordTimelapse, framing: framing ?? self.framing)
    }
}

public nonisolated struct Pomodoro: Codable, Equatable, Sendable {
    public private(set) var settings: PomodoroSettings
    /// When the running focus ends; nil while ready or paused.
    public private(set) var endsAt: Date?
    private var pausedRemaining: TimeInterval?
    private var friendLetOut = false
    /// Counts every focus that ended or was stopped, so one focus can be told from the next (nil in a pomodoro
    /// saved before it existed).
    private var phases: Int?
    private var completed = 0
    private var completedDay: Date?

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
        return pausedRemaining ?? settings.focus
    }

    /// Focus sessions that ran to 0:00 today (stopped ones don't count).
    public func completedToday(at now: Date) -> Int {
        completedDay == Calendar.current.startOfDay(for: now) ? completed : 0
    }

    /// Whether the friend should be home: a started focus, unless the user let it out or turned it off.
    public var friendHome: Bool {
        settings.friendStaysHome && status != .ready && !friendLetOut
    }

    /// What the friend should know while the user focuses with it out, for the model's prompt; nil otherwise.
    public func promptContext(at now: Date) -> String? {
        guard status == .running, !friendHome else { return nil }
        let minutes = max(1, Int((remaining(at: now) / 60).rounded(.up)))
        return "The user is in a focus session with \(minutes) minutes left: keep it short and encouraging."
    }

    /// The moment a change amounts to, if any: the focus ending, starting (not resuming), or the friend being let
    /// out mid-focus. Stopping and settings changes aren't moments.
    public static func moment(from before: Pomodoro, to after: Pomodoro, ended: Bool) -> PomodoroMoment? {
        if ended { return .focusEnded }
        if before.status == .ready, after.status == .running {
            return .focusStarted(minutes: Int(after.settings.focus / 60))
        }
        if before.friendHome, !after.friendHome, after.status != .ready, before.settings == after.settings {
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
            copy.endsAt = now + settings.focus
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

    /// Ends the focus early, uncounted. Today's count stays.
    public func stop() -> Pomodoro {
        status == .ready ? self : finished(countedAt: nil)
    }

    public func letFriendOut() -> Pomodoro {
        var copy = self
        copy.friendLetOut = true
        return copy
    }

    /// Ends the focus if its time is up, counting it toward the day it ended.
    public func settle(at now: Date) -> (pomodoro: Pomodoro, ended: Bool) {
        guard let end = endsAt, end <= now else { return (self, false) }
        return (finished(countedAt: end), true)
    }

    /// Which focus this is, over the pomodoro's life: a timelapse belongs to exactly one.
    public var phaseID: Int { phases ?? 0 }

    private func finished(countedAt: Date?) -> Pomodoro {
        var copy = self
        copy.phases = phaseID + 1
        if let countedAt {
            let day = Calendar.current.startOfDay(for: countedAt)
            copy.completed = (completedDay == day ? completed : 0) + 1
            copy.completedDay = day
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
