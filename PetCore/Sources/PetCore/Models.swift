//
//  Models.swift
//  PetCore
//
//  Wire types for the befriend backend: snake_case JSON inside a {"data": …} envelope, RFC 3339 dates.
//

import Foundation

public nonisolated enum Wire {
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try String(from: decoder)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an RFC 3339 date: \(text)"))
            }
            return date
        }
        return decoder
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Go writes RFC 3339 with 0–9 fractional digits; ISO8601DateFormatter only takes exactly three.
    static func parseDate(_ text: String) -> Date? {
        var normalized = text
        if let dot = text.firstIndex(of: "."),
           let end = text[text.index(after: dot)...].firstIndex(where: { !$0.isNumber }) {
            let digits = String(text[text.index(after: dot)..<end]) + "000"
            normalized = String(text[..<dot]) + "." + String(digits.prefix(3)) + String(text[end...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }
}

// MARK: - Auth

public nonisolated struct AuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let deviceId: String

    public init(accessToken: String, refreshToken: String, deviceId: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceId = deviceId
    }
}

public nonisolated struct DeviceInfo: Encodable, Sendable {
    public let platform: String // ios | macos
    public let name: String

    public init(platform: String, name: String) {
        self.platform = platform
        self.name = name
    }
}

public nonisolated struct Me: Decodable, Equatable, Sendable {
    public let id: String
    public let email: String?
    public let onboardingDone: Bool
}

// MARK: - Onboarding

public nonisolated enum QuestionType: String, Decodable, Sendable {
    case text, choice, slider
}

public nonisolated struct Question: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let type: QuestionType
    public let prompt: String
    public let options: [String]?
    public let maxLength: Int?
    public let min: Int?
    public let max: Int?
    public let minLabel: String?
    public let maxLabel: String?
}

public nonisolated struct QuestionSet: Decodable, Equatable, Sendable {
    public let version: Int
    public let questions: [Question]
}

public nonisolated enum AnswerValue: Encodable, Equatable, Sendable {
    case text(String) // text and choice questions
    case number(Int)  // slider questions

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value): try value.encode(to: encoder)
        case .number(let value): try value.encode(to: encoder)
        }
    }
}

public nonisolated struct OnboardingAnswer: Encodable, Equatable, Sendable {
    public let questionId: String
    public let value: AnswerValue

    public init(questionId: String, value: AnswerValue) {
        self.questionId = questionId
        self.value = value
    }
}

/// City-level birthplace; coordinates are rounded again on the server.
public nonisolated struct OnboardingLocation: Encodable, Equatable, Sendable {
    public let city: String?
    public let countryCode: String?
    public let latitude: Double?
    public let longitude: Double?

    public init(city: String?, countryCode: String?, latitude: Double?, longitude: Double?) {
        self.city = city
        self.countryCode = countryCode
        self.latitude = latitude
        self.longitude = longitude
    }
}

public nonisolated struct CompleteOnboarding: Encodable, Equatable, Sendable {
    public let questionSetVersion: Int
    public let answers: [OnboardingAnswer]
    public let timezone: String
    public let location: OnboardingLocation?
    public let consent: Bool

    public init(questionSetVersion: Int, answers: [OnboardingAnswer], timezone: String, location: OnboardingLocation?, consent: Bool) {
        self.questionSetVersion = questionSetVersion
        self.answers = answers
        self.timezone = timezone
        self.location = location
        self.consent = consent
    }
}

// MARK: - Friend

public nonisolated struct FriendProfile: Codable, Equatable, Sendable {
    public let name: String
    public let userNickname: String
    public let bornAt: Date
    public let birthplace: Birthplace?
    public let timezone: String
    public let chart: Chart
    public let personality: PersonalityState
    public let phrasebook: Phrasebook?

    public var isReady: Bool { personality.status == "ready" && personality.content != nil }
}

public nonisolated struct Birthplace: Codable, Equatable, Sendable {
    public let city: String?
    public let countryCode: String?
}

public nonisolated struct Chart: Codable, Equatable, Sendable {
    public let westernSign: String
    public let chineseAnimal: String
    public let chineseElement: String
    public let chinesePolarity: String
    public let fengShuiStar: Int
    public let fengShuiElement: String
}

public nonisolated struct PersonalityState: Codable, Equatable, Sendable {
    public let status: String // pending | running | ready | failed
    public let version: Int
    public let vocabularyVersion: Int?
    public let content: PersonalityContent?
}

public nonisolated struct PersonalityContent: Codable, Equatable, Sendable {
    public let summary: String
    public let traits: [String]
    public let voice: String
    /// Second-person persona block for the on-device model's instructions.
    public let instructions: String
}

/// Ready-made lines per trigger kind and mood, for when the on-device model can't run.
public nonisolated struct Phrasebook: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public let text: String
        public let action: String // a PetAction raw value; unknown values (newer vocabulary) play idle
    }

    /// lines[trigger kind][mood]
    public let lines: [String: [String: [Line]]]

    public init(lines: [String: [String: [Line]]]) {
        self.lines = lines
    }

    public init(from decoder: Decoder) throws {
        let raw = try [String: [String: [Line]]](from: decoder)
        // Wire.decoder's snake_case conversion rewrites dictionary keys too (app_switched → appSwitched): map back.
        lines = Dictionary(raw.map { (Self.kindKey($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private static func kindKey(_ key: String) -> String {
        let kind = TriggerKind.allCases.first { kind in
            let parts = kind.rawValue.split(separator: "_")
            let camel = parts.prefix(1).joined() + parts.dropFirst().map(\.capitalized).joined()
            return kind.rawValue == key || camel == key
        }
        return kind?.rawValue ?? key
    }

    public func encode(to encoder: Encoder) throws {
        try lines.encode(to: encoder)
    }

    /// A random line for the trigger, in `mood` when the phrasebook has it, otherwise in any mood.
    /// `{app}` is filled with the app name.
    public func reaction(for trigger: Trigger, mood: PetMood? = nil) -> PetReaction? {
        guard let moods = lines[trigger.kind.rawValue] else { return nil }
        let chosen = mood.flatMap { moods[$0.rawValue]?.isEmpty == false ? $0 : nil }
            ?? moods.filter { !$0.value.isEmpty }.keys.compactMap(PetMood.init(rawValue:)).randomElement()
        guard let chosen, let line = moods[chosen.rawValue]?.randomElement() else { return nil }

        let text = trigger.sanitized.appName.map { line.text.replacingOccurrences(of: "{app}", with: $0) } ?? line.text
        return PetReaction(action: PetAction(rawValue: line.action) ?? .idle, mood: chosen, dialogue: text).clamped(for: trigger)
    }
}

// MARK: - Surfaces

/// What the widget and Live Activity show. Also the Live Activity's ContentState, which the backend pushes as
/// JSON with these exact keys (ActivityKit uses a plain JSONDecoder).
public nonisolated struct FriendSurfaceState: Codable, Hashable, Sendable {
    public enum Presence: String, Codable, Hashable, Sendable {
        case here   // the friend is on this iPhone
        case onMac = "mac"
    }

    public let presence: Presence
    public let mood: PetMood
    public let action: PetAction
    public let line: String
    /// Unix seconds.
    public let updatedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case presence, mood, action, line
        case updatedAt = "updated_at"
    }

    public init(presence: Presence, mood: PetMood, action: PetAction, line: String, updatedAt: Date = .now) {
        self.presence = presence
        self.mood = mood
        self.action = action
        self.line = line
        self.updatedAt = updatedAt.timeIntervalSince1970
    }
}

// MARK: - Devices

public nonisolated struct PushTokens: Encodable, Equatable, Sendable {
    public let apnsEnv: String // sandbox | production
    public let laPushToStartToken: String?
    public let laPushToken: String?
    public let laStartedAt: Date?
    public let widgetPushToken: String?

    public init(apnsEnv: String, laPushToStartToken: String? = nil, laPushToken: String? = nil, laStartedAt: Date? = nil, widgetPushToken: String? = nil) {
        self.apnsEnv = apnsEnv
        self.laPushToStartToken = laPushToStartToken
        self.laPushToken = laPushToken
        self.laStartedAt = laStartedAt
        self.widgetPushToken = widgetPushToken
    }
}
