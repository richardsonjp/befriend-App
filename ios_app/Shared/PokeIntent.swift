//
//  PokeIntent.swift
//  befriend (app + widget)
//

import AppIntents

/// Poking the friend from the Dynamic Island or Lock Screen. As a LiveActivityIntent it always runs in the app's
/// process (launched in the background if needed), where the app has installed `handler`.
nonisolated struct PokeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Poke your friend"
    static let isDiscoverable = false

    /// Set by the app at launch. The widget extension only compiles this type to build the button.
    nonisolated(unsafe) static var handler: (@MainActor () async -> Void)?

    init() {}

    func perform() async throws -> some IntentResult {
        await Self.handler?()
        return .result()
    }
}
