import Foundation
import FoundationModels
import Testing
@testable import PetCore

/// A fake 9Router: each test gets its own host, answered by its own handler.
final class NineRouterStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (Int, Data)
    nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    static let lock = NSLock()

    /// Answers `host` on the shared session too (the app's code makes its own clients).
    static func serve(host: String, handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
        _ = registered
    }
    private static let registered: Void = { URLProtocol.registerClass(NineRouterStub.self) }()

    static func session(host: String, handler: @escaping Handler) -> URLSession {
        lock.withLock { handlers[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NineRouterStub.self]
        return URLSession(configuration: configuration)
    }

    /// Only the tests' own hosts (also when registered for the shared session).
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host()?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handlers[request.url?.host() ?? ""] }
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; body.append(buffer, count: read) }
            stream.close()
        }
        do {
            guard let handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

struct NineRouterTests {
    static func router(key: String? = nil, handler: @escaping NineRouterStub.Handler) -> NineRouter {
        let host = "nine-\(UUID().uuidString.lowercased()).test"
        return NineRouter(.init(baseURL: URL(string: "http://\(host)/v1")!, apiKey: key), session: NineRouterStub.session(host: host, handler: handler))
    }

    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    @Test func listsModelsAndSendsTheKeyOnlyWhenThereIsOne() async throws {
        let seen = Box<String?>(nil)
        let handler: NineRouterStub.Handler = { request, _ in
            seen.value = request.value(forHTTPHeaderField: "Authorization")
            #expect(request.url?.path() == "/v1/models")
            return (200, Self.json(["data": [["id": "kr/claude-sonnet-4.5"], ["id": "cc/claude-opus-4-7"], ["id": "befriend-auto"]]]))
        }
        #expect(try await Self.router(handler: handler).models() == ["befriend-auto", "cc/claude-opus-4-7", "kr/claude-sonnet-4.5"])
        #expect(seen.value == nil)
        _ = try await Self.router(key: "sk-local", handler: handler).models()
        #expect(seen.value == "Bearer sk-local")
    }

    @Test func streamsTheAnswerAsItsWritten() async throws {
        let router = Self.router { _, body in
            let sent = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            #expect(sent["stream"] as? Bool == true && sent["model"] as? String == "befriend-auto")
            let events = [": keep-alive", #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
                          #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#, #"data: {"choices":[{"delta":{"content":"lo!"}}]}"#,
                          "data: [DONE]", #"data: {"choices":[{"delta":{"content":"ignored"}}]}"#]
            return (200, Data(events.map { $0 + "\n\n" }.joined().utf8))
        }
        var seen: [String] = []
        for try await text in router.stream([.init(.user, "hi")], model: "befriend-auto") { seen.append(text) }
        #expect(seen == ["Hel", "Hello!"])
    }

    @Test func structuredAnswersUseTheTypesSchema() async throws {
        let router = Self.router { _, body in
            let sent = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let format = sent["response_format"] as! [String: Any]
            let schema = (format["json_schema"] as! [String: Any])
            #expect(format["type"] as? String == "json_schema" && schema["name"] as? String == "Glance")
            #expect(((schema["schema"] as! [String: Any])["required"] as? [String]) == ["kind", "what", "search"])
            let reply = "```json\n{\"kind\":\"error\",\"what\":\"A Python TypeError\",\"search\":\"TypeError int str\"}\n```"
            return (200, Self.json(["choices": [["message": ["role": "assistant", "content": reply]]]]))
        }
        let glance = try await router.respond([.init(.user, "what is this?")], model: "m", generating: ScreenExplainer.Glance.self)
        #expect(glance.kind == .error && glance.what == "A Python TypeError")
    }

    @Test func saysWhatWentWrong() async throws {
        let refused = Self.router { _, _ in (401, Self.json(["error": ["message": "Invalid API key"]])) }
        await #expect(throws: NineRouter.Failure.provider("Invalid API key")) { try await refused.respond([.init(.user, "hi")], model: "m") }
        let streamRefused = Self.router { _, _ in (404, Self.json(["error": ["message": "Unknown model"]])) }
        await #expect(throws: NineRouter.Failure.provider("Unknown model")) {
            for try await _ in streamRefused.stream([.init(.user, "hi")], model: "nope") {}
        }
        let down = NineRouter(.init(baseURL: URL(string: "http://nine-down.test/v1")!), session: NineRouterStub.session(host: "unused.test") { _, _ in (200, Data()) })
        await #expect(throws: NineRouter.Failure.unreachable(URL(string: "http://nine-down.test/v1")!)) { try await down.models() }
        let midStream = Self.router { _, _ in (200, Data("data: {\"error\":{\"message\":\"quota exceeded\"}}\n\n".utf8)) }
        await #expect(throws: NineRouter.Failure.provider("quota exceeded")) {
            for try await _ in midStream.stream([.init(.user, "hi")], model: "m") {}
        }
    }

    @Test func imagesGoAsDataURLs() throws {
        let message = NineRouter.Message(.user, "what's this chart?", image: Data([0x89, 0x50]))
        let parts = message.json["content"] as! [[String: Any]]
        #expect(parts[0]["text"] as? String == "what's this chart?")
        #expect((parts[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,iVA=")
        #expect(NineRouter.Message(.system, "be brief").json["content"] as? String == "be brief")
        #expect(NineRouter.schemaName("Team Engine.Plan") == "Team_Engine_Plan")
    }
}

final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
