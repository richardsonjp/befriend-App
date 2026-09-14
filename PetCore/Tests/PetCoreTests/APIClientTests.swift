import Foundation
import Testing
@testable import PetCore

/// Canned HTTP answers for URLSession, shared by the serialized API suite.
nonisolated final class StubServer: @unchecked Sendable {
    static let shared = StubServer()
    private let lock = NSLock()
    private var handler: (URLRequest) -> (Int, String) = { _ in (500, "") }
    private var log: [URLRequest] = []
    private var files: [String: Data] = [:]

    func reset(_ handler: @escaping (URLRequest) -> (Int, String)) {
        lock.withLock {
            self.handler = handler
            log = []
            files = [:]
        }
    }

    /// Answers requests for `path` with these bytes (status 200) instead of the handler.
    func serve(_ data: Data, at path: String) {
        lock.withLock { files[path] = data }
    }

    func respond(to request: URLRequest) -> (Int, Data) {
        lock.withLock {
            log.append(request)
            if let data = files[request.url?.path ?? ""] { return (200, data) }
            let (status, body) = handler(request)
            return (status, Data(body.utf8))
        }
    }

    func count(path: String) -> Int {
        lock.withLock { log.filter { $0.url?.path == path }.count }
    }
}

nonisolated final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = StubServer.shared.respond(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct APIClientTests {
    let storage: InMemoryTokenStorage
    let client: APIClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        storage = InMemoryTokenStorage(tokens: AuthTokens(accessToken: "old", refreshToken: "r1", deviceId: "d1"))
        client = APIClient(baseURL: URL(string: "https://api.test")!, staticAPIKey: "static", tokens: storage, session: URLSession(configuration: configuration))
    }

    static let me = #"{"data":{"id":"u1","email":null,"onboarding_done":true}}"#
    static let renewed = #"{"data":{"access_token":"new","refresh_token":"r2","device_id":"d1"}}"#

    @Test func concurrentUnauthorizedCallsShareOneRefresh() async throws {
        StubServer.shared.reset { request in
            switch (request.url!.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("/api/auth/refresh", _): (200, Self.renewed)
            case ("/api/me", "Bearer new"): (200, Self.me)
            default: (401, #"{"code":"UNAUTHORIZED","message":"Unauthorized"}"#)
            }
        }
        async let first = client.me()
        async let second = client.me()
        let (a, b) = try await (first, second)

        #expect(a.onboardingDone && b.id == "u1")
        #expect(StubServer.shared.count(path: "/api/auth/refresh") == 1)
        #expect(storage.tokens == AuthTokens(accessToken: "new", refreshToken: "r2", deviceId: "d1"))
    }

    @Test func rejectedRefreshSignsOut() async {
        StubServer.shared.reset { _ in (401, #"{"code":"UNAUTHORIZED","message":"Unauthorized"}"#) }
        await #expect(throws: APIError.signedOut) { try await client.me() }
        #expect(storage.tokens == nil)
    }

    @Test func serverErrorsCarryTheBackendCode() async {
        StubServer.shared.reset { request in
            #expect(request.value(forHTTPHeaderField: "STATIC-API-KEY") == "static")
            return (422, #"{"code":"VALIDATION_FAILED","message":"Validation failed","status":422,"details":["x"]}"#)
        }
        await #expect(throws: APIError.server(status: 422, code: "VALIDATION_FAILED", message: "Validation failed")) {
            try await client.register(email: "a@b.c", password: "password1")
        }
    }

    @Test func friendIsNilBeforeOnboarding() async throws {
        StubServer.shared.reset { _ in (404, #"{"code":"DATA_NOT_FOUND","message":"Not found"}"#) }
        #expect(try await client.friend() == nil)
    }

    @Test func signInStoresTheSession() async throws {
        storage.clear()
        StubServer.shared.reset { request in
            #expect(request.url!.path == "/api/auth/google")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, Self.renewed)
        }
        try await client.signInWithGoogle(idToken: "token", nonce: "nonce-0123456789abcdef", device: DeviceInfo(platform: "ios", name: "Test"))
        #expect(storage.tokens?.accessToken == "new")
        #expect(client.isSignedIn)
    }
}
