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

    @ObservationIgnored private let oneShotDuration: Duration
    @ObservationIgnored private let dialogueDuration: Duration
    @ObservationIgnored private var actionReset: Task<Void, Never>?
    @ObservationIgnored private var dialogueReset: Task<Void, Never>?

    public init(oneShotDuration: Duration = .seconds(2.5), dialogueDuration: Duration = .seconds(6)) {
        self.oneShotDuration = oneShotDuration
        self.dialogueDuration = dialogueDuration
    }

    public func apply(_ reaction: PetReaction) {
        action = reaction.action
        mood = reaction.mood
        dialogue = reaction.dialogue.isEmpty ? nil : reaction.dialogue

        actionReset?.cancel()
        actionReset = reaction.action.isOneShot ? after(oneShotDuration) { $0.action = .idle } : nil

        dialogueReset?.cancel()
        dialogueReset = dialogue == nil ? nil : after(dialogueDuration) { $0.dialogue = nil }
    }

    private func after(_ delay: Duration, _ reset: @escaping (PetStateMachine) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            reset(self)
        }
    }
}
