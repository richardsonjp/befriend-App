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
                FriendPose(state: context.state, size: 44)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.friendName).font(.headline)
                    Text(context.state.displayLine).font(.subheadline).lineLimit(2)
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
                    FriendPose(state: context.state, size: 36)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.friendName).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.displayLine).font(.callout).lineLimit(2)
                        Spacer()
                        Button(intent: PokeIntent()) {
                            Label("Poke", systemImage: "hand.tap.fill")
                        }
                        .tint(context.state.mood.tint)
                    }
                }
            } compactLeading: {
                FriendPose(state: context.state, size: 16)
            } compactTrailing: {
                Circle()
                    .fill(context.state.mood.tint)
                    .frame(width: 10, height: 10)
            } minimal: {
                FriendPose(state: context.state, size: 14)
            }
        }
    }
}

/// A still pose that fits any size: the friend tinted by mood, or a laptop while it's on the Mac.
struct FriendPose: View {
    let state: FriendSurfaceState
    let size: CGFloat

    var body: some View {
        if state.presence == .onMac {
            Image(systemName: "laptopcomputer")
                .font(.system(size: size))
        } else {
            Image(systemName: "cat.fill")
                .font(.system(size: size))
                .foregroundStyle(state.mood.tint)
                .opacity(state.action == .sleep ? 0.6 : 1)
        }
    }
}

extension FriendSurfaceState {
    var displayLine: String {
        presence == .onMac ? "On your Mac" : (line.isEmpty ? "…" : line)
    }
}
