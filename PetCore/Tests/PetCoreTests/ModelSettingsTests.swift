import Foundation
import Testing
@testable import PetCore

@MainActor struct ModelSettingsTests {
    static func defaults() -> UserDefaults { UserDefaults(suiteName: "models-\(UUID().uuidString)")! }

    @Test func everythingStartsOnDevice() {
        let settings = ModelSettings(defaults: Self.defaults(), secret: InMemorySecret())
        for feature in ModelFeature.allCases {
            #expect(settings.choice(for: feature) == .apple && settings.model(for: feature) == nil)
        }
        #expect(settings.baseURL == "http://localhost:20128/v1")
    }

    @Test func choicesAndLimitsAreKeptAndResolved() {
        let defaults = Self.defaults(), secret = InMemorySecret()
        let settings = ModelSettings(defaults: defaults, secret: secret)
        settings.choose(.model("cc/claude-sonnet-4.5"), for: .chat)
        settings.choose(.auto, for: .research)
        settings.setLimits(ModelLimits(limit: 200_000, seesImages: true), for: "cc/claude-sonnet-4.5")
        settings.apiKey = " sk-local "
        settings.knownModels = ["cc/claude-sonnet-4.5", "glm/glm-5.1"]

        let again = ModelSettings(defaults: defaults, secret: secret) // relaunch
        let chat = again.model(for: .chat)
        #expect(chat?.name == "cc/claude-sonnet-4.5" && chat?.limits == ModelLimits(limit: 200_000, seesImages: true))
        #expect(chat?.config.apiKey == "sk-local", "the key from the secret store, trimmed")
        #expect(again.model(for: .research) == nil, "Auto without a combo named stays on-device")
        again.autoCombo = "befriend-auto"
        #expect(again.model(for: .research)?.name == "befriend-auto")
        #expect(again.model(for: .research)?.limits == ModelLimits(), "32K and no images until set")
        #expect(again.knownModels == ["cc/claude-sonnet-4.5", "glm/glm-5.1"])
        #expect(again.model(for: .explain) == nil)
    }

    @Test func aBadAddressMeansOnDevice() {
        let settings = ModelSettings(defaults: Self.defaults(), secret: InMemorySecret())
        settings.choose(.model("m"), for: .chat)
        settings.baseURL = "localhost:20128"
        #expect(settings.config == nil && settings.model(for: .chat) == nil)
        settings.baseURL = "http://127.0.0.1:20128/v1"
        #expect(settings.model(for: .chat)?.config.baseURL.absoluteString == "http://127.0.0.1:20128/v1")
        settings.apiKey = ""
        #expect(settings.config?.apiKey == nil, "no key, no header")
    }
}
