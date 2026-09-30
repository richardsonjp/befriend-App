//
//  PetStateMachine.swift
//  PetCore
//

import Foundation
import Observation

/// What the friend is doing right now. One-shot actions play, then settle back to idle;
/// dialogue clears on its own timer. Any new reaction cancels pending resets.
@Observable
public final class PetStateMachine {
    public private(set) var action: PetAction = .idle
    public private(set) var mood: PetMood = .content
    public private(set) var dialogue: String?
    /// The follow-up a chat-topic line offers; it stays as long as its line.
    public private(set) var followUp: ChatFollowUp?

    @ObservationIgnored private let oneShotDuration: Duration
    @ObservationIgnored private let dialogueDuration: Duration
    @ObservationIgnored private var actionReset: Task<Void, Never>?
    @ObservationIgnored private var dialogueReset: Task<Void, Never>?

    @ObservationIgnored private let followUpDuration: Duration

    /// A chat-topic line stays up to `followUpDuration`, long enough to tap its buttons.
    public init(oneShotDuration: Duration = .seconds(2.5), dialogueDuration: Duration = .seconds(6),
                followUpDuration: Duration = .seconds(60)) {
        self.oneShotDuration = oneShotDuration
        self.dialogueDuration = dialogueDuration
        self.followUpDuration = followUpDuration
    }

    /// The user picked a follow-up (or dismissed it): the bubble can go.
    public func clearFollowUp() {
        guard followUp != nil else { return }
        followUp = nil
        dialogue = nil
        dialogueReset?.cancel()
    }

    public func apply(_ reaction: PetReaction) {
        action = reaction.action
        mood = reaction.mood
        dialogue = reaction.dialogue.isEmpty ? nil : reaction.dialogue
        followUp = dialogue == nil ? nil : reaction.followUp

        actionReset?.cancel()
        actionReset = reaction.action.isOneShot ? after(oneShotDuration) { $0.action = .idle } : nil

        dialogueReset?.cancel()
        dialogueReset = dialogue == nil ? nil : after(followUp == nil ? dialogueDuration : followUpDuration) {
            $0.dialogue = nil
            $0.followUp = nil
        }
    }

    private func after(_ delay: Duration, _ reset: @escaping (PetStateMachine) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            reset(self)
        }
    }
}
