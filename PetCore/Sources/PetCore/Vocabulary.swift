//
//  Vocabulary.swift
//  PetCore
//
//  Vocabulary v1, shared with the backend (backend/pkg/utils/vocabulary). The models generate it, every
//  character draws all of it. Changing a list means bumping the version on both sides.
//

import Foundation
import FoundationModels

public nonisolated enum Vocabulary {
    public static let version = 1
}

@Generable
public nonisolated enum PetAction: String, CaseIterable, Codable, Sendable {
    case idle, wave, nudge, sleep, celebrate, dance, laugh, cry, yawn, stretch
    case think, peek, hide, shrug, facepalm, cheer, jump, spin, sit, love

    /// One-shots play briefly then settle back to idle; the rest hold until the next reaction.
    public var isOneShot: Bool {
        switch self {
        case .idle, .sleep, .think, .hide, .sit: false
        default: true
        }
    }
}

@Generable
public nonisolated enum PetMood: String, CaseIterable, Codable, Sendable {
    case content, curious, concerned, excited, sleepy, bored, playful, proud, shy, grumpy, calm, lonely
}
