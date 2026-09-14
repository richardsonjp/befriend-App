//
//  PetView.swift
//  befriend
//

import AppKit
import PetCore
import SwiftUI

struct PetView: View {
    let pet: PetStateMachine
    let skins: SkinStore
    let walker: FriendWalker
    var poke: () -> Void = {}
    var simulate: (Trigger) -> Void = { _ in }
    /// Where the friend and its bubble are, so the rest of the panel can let clicks through.
    var reportHitAreas: ([CGRect]) -> Void = { _ in }

    @State private var characterFrame = CGRect.zero
    @State private var bubbleFrame = CGRect.zero

    var body: some View {
        VStack(spacing: 16) {
            if let dialogue = pet.dialogue {
                SpeechBubble(text: dialogue)
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { bubbleFrame = $0 }
            }
            CharacterView(
                skin: skins.current,
                action: walker.isHopping ? .jump : pet.action,
                mood: pet.mood,
                walking: walker.isWalking,
                facingLeft: walker.facingLeft
            )
            .scaleEffect(0.2 + 0.8 * walker.hop, anchor: .top)
            .opacity(walker.hop)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { characterFrame = $0 }
            .onTapGesture(perform: poke)
        }
        .animation(.snappy, value: pet.dialogue)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onChange(of: hitAreas, initial: true) { reportHitAreas(hitAreas) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Poke", poke)
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
            Button("Wander Now") { walker.wanderNow() }
            Button("Walk Home") { walker.goHome(instant: false) }
            Divider()
            #endif
            Button("Quit befriend") { NSApp.terminate(nil) }
        }
    }

    private var hitAreas: [CGRect] {
        pet.dialogue == nil ? [characterFrame] : [characterFrame, bubbleFrame]
    }

    private var accessibilityText: String {
        let state = "befriend pet, \(pet.mood.rawValue), \(pet.action.rawValue)"
        return pet.dialogue.map { "\(state): \($0)" } ?? state
    }
}
