//
//  PetView.swift
//  befriend
//

import AppKit
import PetCore
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
                Button("Poked") { simulate(.poked) }
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
