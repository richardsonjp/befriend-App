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
    /// The bubble's follow-up buttons, on a line about an earlier chat.
    var openChat: (ChatStart) -> Void = { _ in }
    /// "Go Home": stays in until "Come Out" in the menu bar, or a focus ends.
    var goHome: () -> Void = {}
    /// Where the friend and its bubble are, so the rest of the panel can let clicks through.
    var reportHitAreas: ([CGRect]) -> Void = { _ in }

    @State private var characterFrame = CGRect.zero
    @State private var bubbleFrame = CGRect.zero

    var body: some View {
        VStack(spacing: 16) {
            if let dialogue = pet.dialogue {
                VStack(spacing: 6) {
                    SpeechBubble(text: dialogue)
                    if let followUp = pet.followUp {
                        FollowUpButtons(followUp: followUp, open: openChat)
                    }
                }
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
        .accessibilityActions {
            if let followUp = pet.followUp {
                Button("Follow up in a new chat") { openChat(ChatStart(conversation: nil, draft: followUp.question)) }
                Button("Continue that chat") { openChat(ChatStart(conversation: followUp.conversationID, draft: followUp.question)) }
            }
        }
        .contextMenu {
            #if DEBUG
            Menu("Simulate Trigger") {
                Button("Encourage") { simulate(.encourage) }
                Button("Bring Up a Chat") { simulate(.chatTopic) }
                Button("Went idle (5 min)") { simulate(.wentIdle(seconds: 300)) }
                Button("Returned after 5 min") { simulate(.returned(afterSeconds: 300)) }
                Button("Poked") { simulate(.poked) }
            }
            Menu("Play Action") {
                ForEach(skins.current?.vocabulary.actions ?? PetAction.builtIn, id: \.self) { action in
                    Button(action.rawValue) { pet.apply(PetReaction(action: action, mood: pet.mood, dialogue: "")) }
                }
            }
            Menu("Set Mood") {
                ForEach(skins.current?.vocabulary.moods ?? PetMood.builtIn, id: \.self) { mood in
                    Button(mood.rawValue) { pet.apply(PetReaction(action: pet.action, mood: mood, dialogue: "")) }
                }
            }
            Button("Wander Now") { walker.wanderNow() }
            Divider()
            #endif
            Button("Go Home", action: goHome)
            Divider()
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
