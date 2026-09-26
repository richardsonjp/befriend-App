//
//  SpeechBubble.swift
//  PetCore
//

import SwiftUI

/// What the friend says, above the character in every skin.
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

public nonisolated extension PetMood {
    /// An accent colour per mood, for controls and dots next to the character.
    var tint: Color {
        Self.tints[rawValue] ?? .orange // a skin's own moods get the default accent
    }

    private static let tints: [String: Color] = [
        "content": .orange, "curious": .teal, "concerned": .indigo, "excited": .pink, "sleepy": .gray,
        "bored": .brown, "playful": .yellow, "proud": .purple, "shy": .mint, "grumpy": .red, "calm": .cyan,
        "lonely": .blue,
    ]
}
