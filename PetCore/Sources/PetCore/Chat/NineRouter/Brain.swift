//
//  Brain.swift
//  PetCore
//
//  The model a piece of work runs on (M37): Apple's on-device model or the user's own through 9Router. Only the two
//  kinds of call the app's makers need (text, and an answer shaped by a schema), so files, diagrams and skills work
//  the same on either.
//

import Foundation
import FoundationModels

public nonisolated enum Brain: Sendable {
    case apple(SystemLanguageModel)
    case nine(ChosenModel)

    public static var onDevice: Brain { .apple(.default) }

    /// The 9Router model's name, for the chip on answers; nil on-device.
    public var modelName: String? {
        if case .nine(let chosen) = self { chosen.name } else { nil }
    }

    public func respond(instructions: String, prompt: String, maxTokens: Int? = nil) async throws -> String {
        switch self {
        case .apple(let model):
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: maxTokens)).content
        case .nine(let chosen):
            return try await NineRouter(chosen.config).respond([.init(.system, instructions), .init(.user, prompt)],
                                                                model: chosen.name, maxTokens: maxTokens)
        }
    }

    public func respond(instructions: String, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
        switch self {
        case .apple(let model):
            return try await LanguageModelSession(model: model, instructions: instructions).respond(to: prompt, schema: schema).content
        case .nine(let chosen):
            return try await NineRouter(chosen.config).respond([.init(.system, instructions), .init(.user, prompt)],
                                                                model: chosen.name, schema: schema)
        }
    }
}
