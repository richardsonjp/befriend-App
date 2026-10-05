//
//  ModelSettings.swift
//  PetCore
//
//  Which model each feature uses (M37): Apple's on-device model, "Auto" (a 9Router combo the user names, so 9Router
//  picks), or one of 9Router's models. Kept in UserDefaults on this device (never synced); 9Router's optional API
//  key lives in the Keychain. Mac only for now: on the iPhone nothing is set, so everything stays on-device.
//

import Foundation
import Observation
import os
import Security

public nonisolated enum ModelFeature: String, CaseIterable, Codable, Sendable {
    case chat, explain, research

    public var title: String {
        switch self {
        case .chat: "Chat"
        case .explain: "Explain"
        case .research: "Research"
        }
    }
}

public nonisolated enum ModelChoice: Codable, Equatable, Hashable, Sendable {
    /// Apple's on-device model, with everything built around it (router, team, 4K budgets).
    case apple
    /// The 9Router combo named in settings: 9Router's own fallback picks the model.
    case auto
    /// One of 9Router's models or combos, by name.
    case model(String)
}

/// What befriend knows about one of 9Router's models: how much to send it, and whether it sees images.
public nonisolated struct ModelLimits: Codable, Equatable, Sendable {
    public static let defaultLimit = 32_000
    public var limit: Int
    public var seesImages: Bool

    public init(limit: Int = ModelLimits.defaultLimit, seesImages: Bool = false) {
        self.limit = limit
        self.seesImages = seesImages
    }
}

/// A 9Router model ready to use: its name and limits, and how to reach it.
public nonisolated struct ChosenModel: Equatable, Sendable {
    public let name: String
    public let limits: ModelLimits
    public let config: NineRouter.Config
}

/// Where a secret lives: the Keychain in the apps, memory in tests.
public protocol SecretStore: AnyObject {
    func load() -> String?
    func save(_ secret: String?)
}

public final class KeychainSecret: SecretStore {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "keychain")
    private let query: [String: Any]

    public init(service: String, account: String) {
        query = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                 kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
    }

    public func load() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ secret: String?) {
        guard let secret, !secret.isEmpty else { SecItemDelete(query as CFDictionary); return }
        let data = Data(secret.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess { Self.log.error("Saving the 9Router key failed: \(status)") }
    }
}

public final class InMemorySecret: SecretStore {
    private var secret: String?
    public init(_ secret: String? = nil) { self.secret = secret }
    public func load() -> String? { secret }
    public func save(_ secret: String?) { self.secret = secret?.isEmpty == true ? nil : secret }
}

@MainActor @Observable
public final class ModelSettings {
    /// The app's settings; tests make their own.
    public static let shared = ModelSettings()

    private struct Stored: Codable, Equatable {
        var baseURL = NineRouter.defaultBaseURL.absoluteString
        var autoCombo = ""
        var choices: [ModelFeature: ModelChoice] = [:]
        var limits: [String: ModelLimits] = [:]
        /// The models 9Router listed last time (for the pickers while it's off).
        var known: [String] = []
        /// What 9Router said about them: the limits used until the user sets their own.
        var listed: [String: ModelLimits] = [:]
        /// The one-time "your text goes to the provider" note was read.
        var privacyRead = false
    }

    private var stored: Stored { didSet { save() } }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secret: SecretStore
    static let defaultsKey = "models.settings"

    public init(defaults: UserDefaults = .standard,
                secret: SecretStore = KeychainSecret(service: "com.richardsonjp.befriend.9router", account: "api-key")) {
        self.defaults = defaults
        self.secret = secret
        stored = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    public var baseURL: String {
        get { stored.baseURL }
        set { stored.baseURL = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public var autoCombo: String {
        get { stored.autoCombo }
        set { stored.autoCombo = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public var apiKey: String {
        get { secret.load() ?? "" }
        set { secret.save(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public var knownModels: [String] {
        get { stored.known }
        set { stored.known = newValue }
    }

    public var privacyRead: Bool {
        get { stored.privacyRead }
        set { stored.privacyRead = newValue }
    }

    public func choice(for feature: ModelFeature) -> ModelChoice { stored.choices[feature] ?? .apple }

    public func choose(_ choice: ModelChoice, for feature: ModelFeature) { stored.choices[feature] = choice }

    public func limits(for model: String) -> ModelLimits { stored.limits[model] ?? stored.listed[model] ?? ModelLimits() }

    /// Most a listed model's window pre-fills its limit with: a whole 1M window per message gets expensive.
    static let listedLimitCap = 128_000

    /// What 9Router listed: the pickers' models, and each one's limit (its window, up to the cap) and image support.
    public func remember(_ listed: [NineRouter.Listed]) {
        stored.known = listed.map(\.id)
        stored.listed = Dictionary(listed.map { model in
            (model.id, ModelLimits(limit: model.window.map { min($0, Self.listedLimitCap) } ?? ModelLimits.defaultLimit, seesImages: model.seesImages))
        }, uniquingKeysWith: { first, _ in first })
    }

    public func setLimits(_ limits: ModelLimits, for model: String) { stored.limits[model] = limits }

    /// How to reach 9Router; nil when the address isn't a web address.
    public var config: NineRouter.Config? {
        guard let url = URL(string: baseURL), ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil else { return nil }
        return NineRouter.Config(baseURL: url, apiKey: apiKey)
    }

    // MARK: Connection

    public enum Connection: Equatable, Sendable {
        /// Not checked yet this launch.
        case unknown
        case checking
        case connected
        /// No key, or 9Router didn't answer: why, for the pickers.
        case unavailable(String)
    }

    /// Whether 9Router answers with the saved key (M39). Until it does, every feature uses Apple's model and the
    /// pickers list only Apple's; the saved choices come back once it connects.
    public internal(set) var connection = Connection.unknown

    public var isConnected: Bool { connection == .connected }

    /// Checks 9Router: lists its models (filling the pickers and each model's limits), then asks one model for a
    /// word, since listing needs no key but answering does. Without a key there's nothing to check.
    public func connect() async {
        guard !apiKey.isEmpty else { return connection = .unavailable("Add your 9Router key in Models… to use your own models.") }
        guard let config else { return connection = .unavailable("The 9Router address in Models… isn't a web address.") }
        connection = .checking
        do {
            let router = NineRouter(config)
            let listed = try await router.models()
            remember(listed)
            let probe = model(named: choice(for: .chat)) ?? (autoCombo.isEmpty ? nil : autoCombo) ?? listed.first?.id
            guard let probe else { return connection = .unavailable("9Router lists no models yet.") }
            _ = try await router.respond([.init(.user, "Reply with the word OK.")], model: probe, maxTokens: 5)
            connection = .connected
        } catch {
            connection = .unavailable(error.localizedDescription)
        }
    }

    private func model(named choice: ModelChoice) -> String? {
        if case .model(let name) = choice { name } else { nil }
    }

    /// The 9Router model a feature uses, or nil for Apple's: also while 9Router isn't connected, when Auto has no
    /// combo named, or when the address is bad.
    public func model(for feature: ModelFeature) -> ChosenModel? {
        guard isConnected, let config else { return nil }
        let name: String
        switch choice(for: feature) {
        case .apple: return nil
        case .auto:
            guard !autoCombo.isEmpty else { return nil }
            name = autoCombo
        case .model(let model): name = model
        }
        return ChosenModel(name: name, limits: limits(for: name), config: config)
    }
}
