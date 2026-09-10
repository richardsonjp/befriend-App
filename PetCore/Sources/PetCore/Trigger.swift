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

    public var kind: TriggerKind {
        switch self {
        case .appSwitched: .appSwitched
        case .wentIdle: .wentIdle
        case .returned: .returned
        case .leftApp: .leftApp
        case .poked: .poked
        case .checkIn: .checkIn
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
