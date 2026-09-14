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
                    FriendPose(state: context.state, size: 48, head: true)
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
                FriendPose(state: context.state, size: 32, head: true)
            } compactTrailing: {
                Circle()
                    .fill(context.state.mood.tint)
                    .frame(width: 10, height: 10)
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
                PixelImage(url: head ? skin.mini(state.mood) : skin.still(state.action, state.mood))
            } else {
                Image(systemName: "cat.fill")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(state.mood.tint)
            }
        }
        .frame(width: size, height: size)
    }
}

extension FriendSurfaceState {
    var displayLine: String {
        presence == .onMac ? "On your Mac" : (line.isEmpty ? "…" : line)
    }
}
