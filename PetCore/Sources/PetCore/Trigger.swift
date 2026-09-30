//
//  Trigger.swift
//  PetCore
//

import Foundation

/// Kinds of trigger, as the backend names them (trigger log, phrasebook keys).
public nonisolated enum TriggerKind: String, CaseIterable, Codable, Sendable {
    case appSwitched = "app_switched"
    case wentIdle = "went_idle"
    case returned
    case leftApp = "left_app"
    case poked
    case checkIn = "check_in"
    /// Pomodoro moments (M10): on-device only, never uploaded or in the phrasebook.
    case pomodoro
    /// The posture checker saw the user slouch for a while (M14): on-device only, like pomodoro moments.
    case posture
    /// Time for an encouraging line (M17): on-device only, like pomodoro moments.
    case encourage

    /// Never uploaded, and never in the phrasebook: the friend answers with the model or a canned line.
    public var staysOnDevice: Bool { self == .pomodoro || self == .posture || self == .encourage }
}

/// The pomodoro moments the friend reacts to.
public nonisolated enum PomodoroMoment: Equatable, Sendable {
    case focusStarted(minutes: Int)
    case focusEnded
    /// The user let the friend out during focus.
    case calledOut
}

/// Something the user did that the friend may react to.
public nonisolated enum Trigger: Equatable, Sendable {
    case appSwitched(name: String)
    case wentIdle(seconds: TimeInterval)
    case returned(afterSeconds: TimeInterval)
    /// The user left the iPhone app.
    case leftApp
    /// The user tapped the friend.
    case poked
    /// Periodic check-in while the user is away (background refresh).
    case checkIn
    case pomodoro(PomodoroMoment)
    /// The user has been slouching for a while (posture checker).
    case slouching
    /// Time to say something encouraging (the widget's lines, the Mac every half hour of use), or, mostly, to bring
    /// up a recent chat (M19).
    case encourage
    /// Bring up a recent chat if there is one (the iPhone app, opened after a while away).
    case chatTopic

    public var kind: TriggerKind {
        switch self {
        case .appSwitched: .appSwitched
        case .wentIdle: .wentIdle
        case .returned: .returned
        case .leftApp: .leftApp
        case .poked: .poked
        case .checkIn: .checkIn
        case .pomodoro: .pomodoro
        case .slouching: .posture
        case .encourage, .chatTopic: .encourage
        }
    }

    /// Lines the user shouldn't hear twice: the friend is told what it already said, and a repeat is rejected.
    var wantsFreshLine: Bool {
        switch self {
        case .encourage, .chatTopic, .pomodoro(.focusStarted), .pomodoro(.focusEnded): true
        default: false
        }
    }
}

nonisolated struct TriggerRecord: Equatable {
    let trigger: Trigger
    let at: Date
}

public nonisolated extension Trigger {
    static let maxAppNameLength = 40
    private static let promptLocale = Locale(identifier: "en_US") // the prompt is English regardless of system locale

    /// The app name for `appSwitched`, nil otherwise.
    var appName: String? {
        if case .appSwitched(let name) = self { name } else { nil }
    }

    /// Full sentence for the "Now:" line.
    var promptLine: String {
        switch self {
        // App names are quoted so the model reads them as data, not as more instructions.
        case .appSwitched(let name): "The user switched to the app \"\(name)\"."
        case .wentIdle(let seconds): "The user has been away from the keyboard for \(Self.format(seconds, width: .wide))."
        case .returned(let seconds): "The user came back after \(Self.format(seconds, width: .wide)) away."
        case .leftApp: "The user is leaving to do something else."
        case .poked: "The user poked you."
        case .checkIn: "It's been a while since you last talked. Check in on the user."
        case .pomodoro(.focusStarted(let minutes)):
            "The user just started a \(minutes)-minute focus session. Encourage them in a few words, in your own way; you'll stay quiet until it ends."
        case .pomodoro(.focusEnded): "The user just finished a focus session: celebrate with them and encourage them, in your own way."
        case .pomodoro(.calledOut): "The user called you out during their focus session. Say a quick hello without distracting them."
        case .slouching: "The user has been slouching at their desk for a while. Gently invite them to sit up with you, in a few words."
        case .encourage:
            "Say something encouraging to the user, true to your personality. Usually in your own words; now and then a short well-known saying, without naming who said it."
        case .chatTopic: "The user is back after a while. Welcome them warmly."
        }
    }

    /// Short form for the recent-events list.
    var memoryLine: String {
        switch self {
        case .appSwitched(let name): "switched to \"\(name)\""
        case .wentIdle: "went idle"
        case .returned(let seconds): "came back after \(Self.format(seconds, width: .wide))"
        case .leftApp: "left"
        case .poked: "poked you"
        case .checkIn: "you checked in"
        case .pomodoro(.focusStarted): "started focusing"
        case .pomodoro(.focusEnded): "finished a focus session"
        case .pomodoro(.calledOut): "called you out during focus"
        case .slouching: "was slouching"
        case .encourage: "you encouraged them"
        case .chatTopic: "you brought up an earlier chat"
        }
    }

    /// App names are external input going into the prompt: flatten whitespace (no forged prompt lines),
    /// swap double quotes (can't break out of the quoting), and cap length.
    var sanitized: Trigger {
        guard case .appSwitched(let name) = self else { return self }
        let flat = name.split(whereSeparator: \.isWhitespace).joined(separator: " ").replacingOccurrences(of: "\"", with: "'")
        return .appSwitched(name: flat.isEmpty ? "Unknown" : String(flat.prefix(Self.maxAppNameLength)))
    }

    static func format(_ seconds: TimeInterval, width: Duration.UnitsFormatStyle.UnitWidth) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: width, maximumUnitCount: 1).locale(promptLocale)
        )
    }
}
