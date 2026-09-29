//
//  FriendLiveActivity.swift
//  FriendWidget
//

import ActivityKit
import AppIntents
import PetCore
import SwiftUI
import WidgetKit

struct FriendLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FriendActivityAttributes.self) { context in
            HStack(spacing: 16) {
                FriendPose(state: context.state, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.friendName).font(.headline)
                    if let pomodoro = context.state.pomodoro {
                        PomodoroRow(pomodoro: pomodoro, isStale: context.isStale)
                    } else {
                        Text(context.state.displayLine).font(.subheadline).lineLimit(2)
                    }
                }
                Spacer()
                Button(intent: PokeIntent()) {
                    Image(systemName: "hand.tap.fill")
                }
                .tint(context.state.mood.tint)
                .accessibilityLabel("Poke \(context.attributes.friendName)")
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FriendPose(state: context.state, size: 48, head: true)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.friendName).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let pomodoro = context.state.pomodoro {
                        PomodoroRow(pomodoro: pomodoro, isStale: context.isStale)
                    } else {
                        HStack {
                        Text(context.state.displayLine).font(.callout).lineLimit(2)
                        Spacer()
                        Button(intent: PokeIntent()) {
                            Label("Poke", systemImage: "hand.tap.fill")
                        }
                        .tint(context.state.mood.tint)
                        }
                    }
                }
            } compactLeading: {
                FriendPose(state: context.state, size: 32, head: true)
            } compactTrailing: {
                if let pomodoro = context.state.pomodoro, !context.isStale {
                    PomodoroClock(pomodoro: pomodoro).frame(maxWidth: 52)
                } else {
                    Circle()
                        .fill(context.state.mood.tint)
                        .frame(width: 10, height: 10)
                }
            } minimal: {
                FriendPose(state: context.state, size: 32, head: true)
            }
        }
    }
}

/// A still of the friend in the account's skin, or a laptop while it's on the Mac. `head` draws the 16-pixel
/// head made for the Dynamic Island. Sizes are whole multiples of the pixels, so they stay crisp.
struct FriendPose: View {
    let state: FriendSurfaceState
    let size: CGFloat
    var head = false

    var body: some View {
        Group {
            if state.presence == .onMac {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: size * 0.6))
            } else if let skin = SkinInstaller.current(in: SharedStore.skinsRoot) {
                PixelImage(url: head ? skin.mini(state.mood)
                           : state.pomodoro?.focusing == true ? skin.still(clip: InstalledSkin.focus, state.mood)
                           : skin.still(state.action, state.mood))
            } else {
                Image(systemName: "cat.fill")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(state.mood.tint)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The countdown while a focus runs (the system ticks it), or the time left while paused or waiting.
struct PomodoroClock: View {
    let pomodoro: PomodoroSurface

    var body: some View {
        Group {
            if let end = pomodoro.endDate, !pomodoro.paused {
                Text(timerInterval: Date.now...max(end, .now), countsDown: true)
            } else {
                Text(Pomodoro.clock(pomodoro.remaining))
            }
        }
        .monospacedDigit()
    }
}

/// The focus countdown and its buttons, without opening the app.
struct PomodoroRow: View {
    let pomodoro: PomodoroSurface
    /// The focus's time is up; the app hasn't caught up yet.
    let isStale: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if isStale {
                    Text("00:00").font(.title3.bold()).monospacedDigit()
                } else {
                    PomodoroClock(pomodoro: pomodoro).font(.title3.bold())
                }
            }
            Spacer()
            if isStale {
                button("stop", "Done", "checkmark")
            } else if pomodoro.endsAt != nil {
                button("pause", "Pause", "pause.fill")
                button("stop", "Stop", "stop.fill")
            } else {
                button("start", "Resume", "play.fill")
                button("stop", "Stop", "stop.fill")
            }
        }
    }

    private var title: String {
        if isStale { return "Focus done 🍅" }
        if pomodoro.timelapse == .paused { return "Recording paused · open befriend" }
        if pomodoro.timelapse == .recording { return "● Recording · Focus" }
        if pomodoro.paused { return "Paused · Focus" }
        return pomodoro.focusing ? "Focusing together" : "Focus"
    }

    private func button(_ command: String, _ label: String, _ symbol: String) -> some View {
        Button(intent: PomodoroIntent(command)) {
            Image(systemName: symbol)
        }
        .accessibilityLabel(label)
    }
}

extension FriendSurfaceState {
    var displayLine: String {
        presence == .onMac ? "On your Mac" : (line.isEmpty ? "…" : line)
    }
}
