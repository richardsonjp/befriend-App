import Foundation
import Testing
@testable import PetCore

/// Shaped like GET /api/friend once the personality is ready (dates as Go writes them).
let friendJSON = """
{"data":{"name":"Mochi","user_nickname":"Rich","born_at":"2026-09-11T02:55:48.123456789+07:00",
"birthplace":{"city":"Jakarta","country_code":"ID"},"timezone":"Asia/Jakarta",
"chart":{"western_sign":"virgo","chinese_animal":"horse","chinese_element":"fire","chinese_polarity":"yang","feng_shui_star":1,"feng_shui_element":"water"},
"personality":{"status":"ready","version":1,"vocabulary_version":1,"content":{"summary":"A sleepy cat.","traits":["curious","gentle","dramatic"],"voice":"Soft.","instructions":"You are Mochi. Keep it short."}},
"phrasebook":{"app_switched":{"curious":[{"text":"Ooh, {app}?","action":"peek"}]},"poked":{"playful":[{"text":"Hehe!","action":"laugh"}],"shy":[{"text":"Eep.","action":"brand_new_action"}]}}}}
"""

struct WireTests {
    @Test(arguments: [
        ("2026-09-11T02:55:48+07:00", 1_789_070_148.0),
        ("2026-09-10T19:55:48Z", 1_789_070_148.0),
        ("2026-09-10T19:55:48.5Z", 1_789_070_148.5),
        ("2026-09-10T19:55:48.123456789Z", 1_789_070_148.123),
    ])
    func parsesGoDates(text: String, seconds: Double) throws {
        let date = try #require(Wire.parseDate(text))
        #expect(abs(date.timeIntervalSince1970 - seconds) < 0.001)
    }

    @Test func decodesFriendProfile() throws {
        struct Envelope: Decodable { let data: FriendProfile }
        let friend = try Wire.decoder.decode(Envelope.self, from: Data(friendJSON.utf8)).data
        #expect(friend.isReady)
        #expect(friend.userNickname == "Rich")
        #expect(friend.chart.fengShuiStar == 1)
        #expect(friend.birthplace?.countryCode == "ID")
        #expect(friend.personality.content?.traits.count == 3)
        #expect(friend.phrasebook?.lines["poked"]?.count == 2)
        #expect(friend.phrasebook?.lines["app_switched"] != nil) // not camel-cased by the snake_case decoder
    }

    @Test func encodesOnboardingInSnakeCase() throws {
        let payload = CompleteOnboarding(
            questionSetVersion: 1,
            answers: [OnboardingAnswer(questionId: "friend_name", value: .text("Mochi")), OnboardingAnswer(questionId: "energy", value: .number(7))],
            timezone: "Asia/Jakarta",
            location: nil,
            consent: true
        )
        let json = try #require(try JSONSerialization.jsonObject(with: Wire.encoder.encode(payload)) as? [String: Any])
        #expect(json["question_set_version"] as? Int == 1)
        let answers = try #require(json["answers"] as? [[String: Any]])
        #expect(answers[0]["question_id"] as? String == "friend_name")
        #expect(answers[0]["value"] as? String == "Mochi")
        #expect(answers[1]["value"] as? Int == 7)
    }

    @Test func surfaceStateUsesBackendKeys() throws {
        let pushed = #"{"presence":"mac","mood":"calm","action":"sit","line":"On your Mac","updated_at":1789156548}"#
        let state = try JSONDecoder().decode(FriendSurfaceState.self, from: Data(pushed.utf8))
        #expect(state.presence == .onMac && state.action == .sit && state.updatedAt == 1_789_156_548)
        let roundTrip = try JSONDecoder().decode(FriendSurfaceState.self, from: JSONEncoder().encode(state))
        #expect(roundTrip == state)
    }
}

struct PhrasebookTests {
    let book: Phrasebook = {
        struct Envelope: Decodable { let data: FriendProfile }
        return try! Wire.decoder.decode(Envelope.self, from: Data(friendJSON.utf8)).data.phrasebook!
    }()

    @Test func fillsSanitizedAppName() throws {
        let reaction = try #require(book.reaction(for: .appSwitched(name: "Final\nCut \"Pro\"")))
        #expect(reaction.dialogue == "Ooh, Final Cut 'Pro'?")
        #expect(reaction.action == .peek && reaction.mood == .curious)
    }

    @Test func prefersRequestedMoodAndToleratesUnknownActions() throws {
        #expect(book.reaction(for: .poked, mood: .playful)?.dialogue == "Hehe!")
        let shy = try #require(book.reaction(for: .poked, mood: .shy))
        #expect(shy.action == PetAction("brand_new_action"), "skins name their own actions; drawing falls back to idle")
        // A mood the phrasebook lacks falls back to one it has.
        #expect(["Hehe!", "Eep."].contains(book.reaction(for: .poked, mood: .grumpy)?.dialogue))
    }

    @Test func missingKindHasNoLine() {
        #expect(book.reaction(for: .checkIn) == nil)
    }
}

struct InstructionsTests {
    @Test func friendNameNicknameAndPersona() throws {
        struct Envelope: Decodable { let data: FriendProfile }
        let friend = try Wire.decoder.decode(Envelope.self, from: Data(friendJSON.utf8)).data
        let text = PetBrain.makeInstructions(for: friend)
        #expect(text.hasPrefix(PetBrain.baseInstructions))
        #expect(text.contains("Your name is \"Mochi\". Call the user \"Rich\"."))
        #expect(text.hasSuffix("You are Mochi. Keep it short."))
        #expect(PetBrain.makeInstructions(for: nil) == PetBrain.baseInstructions)
    }
}
