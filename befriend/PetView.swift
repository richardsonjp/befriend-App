//
//  PetView.swift
//  befriend
//

import SwiftUI

struct PetView: View {
    let pet: PetStateMachine
    var simulate: (Trigger) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 16) {
            if let dialogue = pet.dialogue {
                SpeechBubble(text: dialogue)
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
            }
            PlaceholderCharacterView(action: pet.action, mood: pet.mood)
        }
        .animation(.snappy, value: pet.dialogue)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .contextMenu {
            #if DEBUG
            Menu("Simulate Trigger") {
                Button("Switched to Safari") { simulate(.appSwitched(name: "Safari")) }
                Button("Went idle (5 min)") { simulate(.wentIdle(seconds: 300)) }
                Button("Returned after 5 min") { simulate(.returned(afterSeconds: 300)) }
            }
            Menu("Play Action") {
                ForEach(PetAction.allCases, id: \.self) { action in
                    Button(action.rawValue) { pet.apply(PetReaction(action: action, mood: pet.mood, dialogue: "")) }
                }
            }
            Menu("Set Mood") {
                ForEach(PetMood.allCases, id: \.self) { mood in
                    Button(mood.rawValue) { pet.apply(PetReaction(action: pet.action, mood: mood, dialogue: "")) }
                }
            }
            Divider()
            #endif
            Button("Quit befriend") { NSApp.terminate(nil) }
        }
    }

    private var accessibilityText: String {
        let state = "befriend pet, \(pet.mood.rawValue), \(pet.action.rawValue)"
        return pet.dialogue.map { "\(state): \($0)" } ?? state
    }
}

/// Shared by every character, so it lives outside PlaceholderCharacterView.
struct SpeechBubble: View {
    private static let maxWidth: CGFloat = 220
    private static let background = Color(nsColor: .windowBackgroundColor)

    let text: String

    var body: some View {
        Text(text) // plain String: rendered verbatim, no markdown from model output
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Self.background, in: RoundedRectangle(cornerRadius: 12))
            .background(alignment: .bottom) {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Self.background)
                    .offset(y: 8)
            }
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .frame(maxWidth: Self.maxWidth)
    }
}

/// The only character-specific code. A future character swaps this view; generation never touches it.
// ponytail: single character, no Character protocol until the picker exists.
struct PlaceholderCharacterView: View {
    private static let catSize: CGFloat = 64
    private static let accessorySize: CGFloat = 26

    let action: PetAction
    let mood: PetMood

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cat
            accessory
                .font(.system(size: Self.accessorySize))
                .offset(x: 26, y: -4) // beside the head, clear of the speech bubble
        }
        .foregroundStyle(mood.tint)
        .shadow(radius: 2)
        .id(action) // restart the per-action animation on every change
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .animation(.snappy, value: action)
        .animation(.easeInOut, value: mood)
    }

    @ViewBuilder private var cat: some View {
        let image = Image(systemName: "cat.fill").font(.system(size: Self.catSize))
        if reduceMotion {
            image.opacity(action == .sleep ? 0.55 : 1)
        } else {
            switch action {
            case .idle:
                image.phaseAnimator([1.0, 1.04]) { content, scale in
                    content.scaleEffect(scale, anchor: .bottom)
                } animation: { _ in .easeInOut(duration: 1.6) }
            case .wave:
                image.symbolEffect(.bounce, options: .repeat(2))
            case .nudge:
                image.keyframeAnimator(initialValue: 0.0, repeating: true) { content, x in
                    content.offset(x: x)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(-8, duration: 0.08)
                        CubicKeyframe(8, duration: 0.16)
                        CubicKeyframe(0, duration: 0.08)
                        LinearKeyframe(0, duration: 0.4)
                    }
                }
            case .sleep:
                image.opacity(0.55)
            case .celebrate:
                image.symbolEffect(.bounce, options: .repeat(.continuous))
            }
        }
    }

    @ViewBuilder private var accessory: some View {
        switch action {
        case .wave: Image(systemName: "hand.wave.fill").symbolEffect(.wiggle, options: .repeat(.continuous))
        case .sleep: Image(systemName: "zzz").symbolEffect(.pulse)
        case .celebrate: Image(systemName: "sparkles").symbolEffect(.variableColor.iterative)
        case .idle, .nudge: EmptyView()
        }
    }
}

private extension PetMood {
    var tint: Color {
        switch self {
        case .content: .orange
        case .curious: .teal
        case .concerned: .indigo
        case .excited: .pink
        }
    }
}
