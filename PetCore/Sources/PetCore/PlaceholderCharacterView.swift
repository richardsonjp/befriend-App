//
//  PlaceholderCharacterView.swift
//  PetCore
//

import SwiftUI

/// Shared by every character, so it lives outside PlaceholderCharacterView.
public struct SpeechBubble: View {
    private static let maxWidth: CGFloat = 220

    let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text) // plain String: rendered verbatim, no markdown from model output
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .background(alignment: .bottom) {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.background)
                    .offset(y: 8)
            }
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .frame(maxWidth: Self.maxWidth)
    }
}

/// The only character-specific code: skins replace this view, and each must draw every action and mood.
// ponytail: single character, no Character protocol until the skin picker exists.
public struct PlaceholderCharacterView: View {
    private static let catSize: CGFloat = 64
    private static let accessorySize: CGFloat = 26

    let action: PetAction
    let mood: PetMood
    /// Widgets and Live Activities render one frame; no animation.
    let isStatic: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(action: PetAction, mood: PetMood, isStatic: Bool = false) {
        self.action = action
        self.mood = mood
        self.isStatic = isStatic
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            cat
            if let symbol = action.accessorySymbol {
                Image(systemName: symbol)
                    .font(.system(size: Self.accessorySize))
                    .symbolEffect(.pulse, options: .repeat(.continuous))
                    .symbolEffectsRemoved(isStill)
                    .offset(x: 26, y: -4) // beside the head, clear of the speech bubble
            }
        }
        .foregroundStyle(mood.tint)
        .shadow(radius: 2)
        .id(action) // restart the per-action animation on every change
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .animation(.snappy, value: action)
        .animation(.easeInOut, value: mood)
    }

    private var isStill: Bool { isStatic || reduceMotion }

    @ViewBuilder private var cat: some View {
        let image = Image(systemName: "cat.fill").font(.system(size: Self.catSize))
        switch action {
        case .sleep: image.opacity(0.55)
        case .hide: image.opacity(0.25).scaleEffect(0.85, anchor: .bottom)
        case .cry: image.opacity(0.8)
        case .sit: image.scaleEffect(x: 1.05, y: 0.9, anchor: .bottom)
        case .think: image.rotationEffect(.degrees(-6), anchor: .bottom)
        case _ where isStill: image
        case .idle:
            image.phaseAnimator([1.0, 1.04]) { $0.scaleEffect($1, anchor: .bottom) } animation: { _ in .easeInOut(duration: 1.6) }
        case .wave:
            image.symbolEffect(.bounce, options: .repeat(2))
        case .celebrate, .cheer, .laugh:
            image.symbolEffect(.bounce, options: .repeat(.continuous))
        case .love:
            image.symbolEffect(.breathe, options: .repeat(.continuous))
        case .spin:
            image.symbolEffect(.rotate, options: .repeat(.continuous))
        case .nudge:
            image.phaseAnimator([0.0, -8, 8]) { $0.offset(x: $1) } animation: { _ in .easeInOut(duration: 0.1) }
        case .dance:
            image.phaseAnimator([-12.0, 12]) { $0.rotationEffect(.degrees($1), anchor: .bottom) } animation: { _ in .easeInOut(duration: 0.3) }
        case .jump:
            image.phaseAnimator([0.0, -18]) { $0.offset(y: $1) } animation: { _ in .easeOut(duration: 0.25) }
        case .stretch, .yawn:
            image.phaseAnimator([1.0, 1.15]) { $0.scaleEffect(x: 1, y: $1, anchor: .bottom) } animation: { _ in .easeInOut(duration: 0.6) }
        case .peek:
            image.phaseAnimator([14.0, 0]) { $0.offset(y: $1) } animation: { _ in .easeInOut(duration: 0.8) }
        case .shrug, .facepalm:
            image.phaseAnimator([0.0, -8]) { $0.rotationEffect(.degrees($1), anchor: .bottom) } animation: { _ in .easeInOut(duration: 0.5) }
        }
    }
}

nonisolated extension PetAction {
    /// A symbol drawn beside the character, for actions the pose alone doesn't read as.
    var accessorySymbol: String? {
        switch self {
        case .wave: "hand.wave.fill"
        case .sleep: "zzz"
        case .celebrate: "sparkles"
        case .dance: "music.note"
        case .laugh: "face.smiling"
        case .cry: "drop.fill"
        case .yawn: "moon.fill"
        case .think: "ellipsis.bubble.fill"
        case .hide: "eye.slash.fill"
        case .shrug: "questionmark"
        case .facepalm: "hand.raised.fill"
        case .cheer: "star.fill"
        case .love: "heart.fill"
        case .idle, .nudge, .stretch, .peek, .jump, .spin, .sit: nil
        }
    }
}

public nonisolated extension PetMood {
    var tint: Color {
        switch self {
        case .content: .orange
        case .curious: .teal
        case .concerned: .indigo
        case .excited: .pink
        case .sleepy: .gray
        case .bored: .brown
        case .playful: .yellow
        case .proud: .purple
        case .shy: .mint
        case .grumpy: .red
        case .calm: .cyan
        case .lonely: .blue
        }
    }
}
