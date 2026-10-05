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
        #expect(again.model(for: .chat) == nil, "nothing leaves this Mac until 9Router answers")
        again.connection = .connected
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
        settings.connection = .connected
        settings.choose(.model("m"), for: .chat)
        settings.baseURL = "localhost:20128"
        #expect(settings.config == nil && settings.model(for: .chat) == nil)
        settings.baseURL = "http://127.0.0.1:20128/v1"
        #expect(settings.model(for: .chat)?.config.baseURL.absoluteString == "http://127.0.0.1:20128/v1")
        settings.apiKey = ""
        #expect(settings.config?.apiKey == nil, "no key, no header")
    }

    @Test func whatNineRouterListsFillsTheLimitsUntilSet() {
        let settings = ModelSettings(defaults: Self.defaults(), secret: InMemorySecret())
        settings.remember([.init(id: "ag/gemini-3.8-flash", window: 1_048_576, seesImages: true), .init(id: "ag/gpt-oss", window: 128_000, seesImages: false),
                           .init(id: "combo", window: nil, seesImages: false)])
        #expect(settings.knownModels == ["ag/gemini-3.8-flash", "ag/gpt-oss", "combo"])
        #expect(settings.limits(for: "ag/gemini-3.8-flash") == ModelLimits(limit: 128_000, seesImages: true), "a 1M window, capped")
        #expect(settings.limits(for: "combo") == ModelLimits(), "nothing said: 32K, no images")
        settings.setLimits(ModelLimits(limit: 500_000, seesImages: false), for: "ag/gemini-3.8-flash")
        #expect(settings.limits(for: "ag/gemini-3.8-flash").limit == 500_000, "the user's own setting wins")
    }

    @Test func onlyApplesUntilNineRouterAnswersWithTheKey() async {
        let settings = ModelSettings(defaults: Self.defaults(), secret: InMemorySecret())
        settings.choose(.model("ag/m"), for: .chat)
        await settings.connect()
        #expect(settings.connection == .unavailable("Add your 9Router key in Models… to use your own models."))
        #expect(settings.model(for: .chat) == nil)

        let host = "nine-\(UUID().uuidString.lowercased()).test"
        let refuses = Box(true)
        NineRouterStub.serve(host: host) { request, _ in
            if request.url?.path().hasSuffix("/models") == true { return (200, NineRouterTests.json(["data": [["id": "ag/m"]]])) }
            return refuses.value ? (401, NineRouterTests.json(["error": ["message": "Invalid API key"]]))
                : (200, NineRouterTests.json(["choices": [["message": ["content": "OK"]]]]))
        }
        settings.baseURL = "http://\(host)/v1"
        settings.apiKey = "sk-wrong"
        await settings.connect()
        #expect(settings.connection == .unavailable("9Router: Invalid API key"), "listing works without a key; answering shows it's wrong")
        #expect(settings.knownModels == ["ag/m"] && settings.model(for: .chat) == nil)
        refuses.value = false
        await settings.connect()
        #expect(settings.isConnected && settings.model(for: .chat)?.name == "ag/m", "the saved choice comes back")
    }
}
