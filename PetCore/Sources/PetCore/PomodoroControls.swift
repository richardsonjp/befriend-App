//
//  PomodoroControls.swift
//  PetCore
//

import SwiftUI

/// The pomodoro's controls: the Mac's menu bar popover and the iPhone's Home screen card. `more`, when given, adds
/// a "…" button (the Mac's old menu).
public struct PomodoroControls: View {
    let pomodoro: PomodoroRunner
    let more: (() -> Void)?
    @State private var showsSettings = false

    public init(pomodoro: PomodoroRunner, more: (() -> Void)? = nil) {
        self.pomodoro = pomodoro
        self.more = more
    }

    public var body: some View {
        let state = pomodoro.state
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("🍅 \(state.phase.title)").font(.headline)
                Spacer()
                Text("Today: \(state.completedToday(at: pomodoro.now))").foregroundStyle(.secondary)
            }
            Text(Pomodoro.clock(state.remaining(at: pomodoro.now)))
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
            rounds(state)
            HStack {
                primaryButton(state).keyboardShortcut(.defaultAction)
                Button("Skip") { pomodoro.skip() }
                Button("Reset") { pomodoro.reset() }.disabled(state.status == .ready && state.phase == .focus && state.round == 1)
            }
            Toggle("Friend stays home during focus", isOn: setting(\.friendStaysHome) { $0.with(friendStaysHome: $1) })
            if state.friendHome {
                Button("Let friend out") { pomodoro.letFriendOut() }
            }
            Divider()
            HStack {
                Button { showsSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Pomodoro settings")
                Spacer()
                if let more {
                    Button { more() } label: { Image(systemName: "ellipsis.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("More")
                }
            }
            if showsSettings { settings(state.settings) }
        }
    }

    @ViewBuilder
    private func primaryButton(_ state: Pomodoro) -> some View {
        switch state.status {
        case .ready: Button("Start \(state.phase.title.lowercased())") { pomodoro.start() }
        case .running: Button("Pause") { pomodoro.pause() }
        case .paused: Button("Resume") { pomodoro.start() }
        }
    }

    /// A dot per focus round in the cycle; finished ones filled.
    private func rounds(_ state: Pomodoro) -> some View {
        let every = state.settings.longBreakEvery
        let done = state.round - (state.phase == .focus ? 1 : 0)
        return HStack(spacing: 6) {
            ForEach(1...every, id: \.self) { index in
                Circle()
                    .fill(index <= done ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
            Text("round \(state.round) of \(every)").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Round \(state.round) of \(every)")
    }

    private func settings(_ current: PomodoroSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper("Focus: \(Int(current.focus / 60)) min", value: minutes(\.focus) { $0.with(focus: $1) }, in: 1...180)
            Stepper("Short break: \(Int(current.shortBreak / 60)) min", value: minutes(\.shortBreak) { $0.with(shortBreak: $1) }, in: 1...180)
            Stepper("Long break: \(Int(current.longBreak / 60)) min", value: minutes(\.longBreak) { $0.with(longBreak: $1) }, in: 1...180)
            Stepper("Long break every \(current.longBreakEvery) rounds",
                    value: setting(\.longBreakEvery) { $0.with(longBreakEvery: $1) }, in: PomodoroSettings.rounds)
            Toggle("Start the next phase automatically", isOn: setting(\.autoStart) { $0.with(autoStart: $1) })
            Toggle("Sound at phase end", isOn: setting(\.sound) { $0.with(sound: $1) })
        }
    }

    private func setting<Value>(_ read: KeyPath<PomodoroSettings, Value>,
                                _ write: @escaping (PomodoroSettings, Value) -> PomodoroSettings) -> Binding<Value> {
        Binding(get: { pomodoro.state.settings[keyPath: read] },
                set: { pomodoro.update(write(pomodoro.state.settings, $0)) })
    }

    private func minutes(_ read: KeyPath<PomodoroSettings, TimeInterval>,
                         _ write: @escaping (PomodoroSettings, TimeInterval) -> PomodoroSettings) -> Binding<Int> {
        Binding(get: { Int(pomodoro.state.settings[keyPath: read] / 60) },
                set: { pomodoro.update(write(pomodoro.state.settings, TimeInterval($0 * 60))) })
    }
}
