//
//  PomodoroIntent.swift
//  befriend (app + widget)
//

import AppIntents

/// The pomodoro's buttons in the Live Activity (M10). Like PokeIntent it runs in the app's process, launched in the
/// background if needed, where the app has installed `handler`.
struct PomodoroIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control the focus timer"
    static let isDiscoverable = false

    /// start (also resumes), pause or stop.
    @Parameter(title: "Command") var command: String

    /// Set by the app at launch.
    nonisolated(unsafe) static var handler: (@MainActor (String) async -> Void)?

    init() {}

    init(_ command: String) {
        self.command = command
    }

    func perform() async throws -> some IntentResult {
        await Self.handler?(command)
        return .result()
    }
}
