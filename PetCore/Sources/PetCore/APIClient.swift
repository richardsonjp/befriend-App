//
//  APIClient.swift
//  PetCore
//

import Foundation

public nonisolated enum APIError: Error, Equatable, Sendable {
    /// No session, or the server ended it (refresh rejected, account deleted). Show sign-in.
    case signedOut
    /// A non-2xx answer: `code` is the backend's error code (VALIDATION_FAILED, DATA_CONFLICT, …).
    case server(status: Int, code: String, message: String)
    case invalidResponse
}

/// The befriend backend. Every request carries the static API key; signed-in requests carry the access token,
/// and a 401 refreshes the session once (concurrent callers share that refresh) and retries.
public final class APIClient {
    let baseURL: URL
    let staticAPIKey: String
    let tokens: TokenStorage
    private let session: URLSession
    private var refreshing: Task<AuthTokens, Error>?

    public init(baseURL: URL, staticAPIKey: String, tokens: TokenStorage, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.staticAPIKey = staticAPIKey
        self.tokens = tokens
        self.session = session
    }

    public var isSignedIn: Bool { tokens.load() != nil }
    public var deviceID: String? { tokens.load()?.deviceId }

    // MARK: Email

    public func register(email: String, password: String) async throws {
        try await sendIgnoringData("POST", "auth/register", body: Credentials(email: email, password: password), authorized: false)
    }

    public func verifyEmail(email: String, code: String) async throws {
        try await sendIgnoringData("POST", "auth/verify-email", body: VerifyEmail(email: email, otpCode: code), authorized: false)
    }

    public func resendCode(email: String) async throws {
        try await sendIgnoringData("POST", "auth/resend-code", body: EmailOnly(email: email), authorized: false)
    }

    public func login(email: String, password: String, device: DeviceInfo) async throws {
        try await signIn("auth/login", body: EmailLogin(email: email, password: password, device: device))
    }

    // MARK: Providers

    /// `nonce` is the raw nonce; its SHA-256 went to Apple.
    public func signInWithApple(identityToken: String, authorizationCode: String?, nonce: String, device: DeviceInfo) async throws {
        try await signIn("auth/apple", body: AppleLogin(identityToken: identityToken, authorizationCode: authorizationCode ?? "", nonce: nonce, device: device))
    }

    public func signInWithGoogle(idToken: String, nonce: String, device: DeviceInfo) async throws {
        try await signIn("auth/google", body: GoogleLogin(idToken: idToken, nonce: nonce, device: device))
    }

    // MARK: Session

    /// Ends the session locally even if the server can't be reached.
    public func logout() async {
        try? await sendIgnoringData("POST", "auth/logout")
        tokens.clear()
    }

    public func deleteAccount() async throws {
        try await sendIgnoringData("DELETE", "me")
        tokens.clear()
    }

    public func me() async throws -> Me {
        try await send("GET", "me")
    }

    // MARK: Friend

    public func questions() async throws -> QuestionSet {
        try await send("GET", "onboarding/questions")
    }

    public func completeOnboarding(_ payload: CompleteOnboarding) async throws -> FriendProfile {
        try await send("POST", "onboarding/complete", body: payload)
    }

    /// Nil until onboarding is complete.
    public func friend() async throws -> FriendProfile? {
        do {
            return try await send("GET", "friend") as FriendProfile
        } catch APIError.server(status: 404, _, _) {
            return nil
        }
    }

    public func updatePushTokens(_ pushTokens: PushTokens) async throws {
        try await sendIgnoringData("PUT", "devices/me/push-tokens", body: pushTokens)
    }

    // MARK: Transport

    private func signIn(_ path: String, body: some Encodable) async throws {
        let session: AuthTokens = try await send("POST", path, body: body, authorized: false)
        tokens.save(session)
    }

    func storeSession(_ session: AuthTokens) {
        tokens.save(session)
    }

    func send<Response: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil, authorized: Bool = true) async throws -> Response {
        let data = try await sendRaw(method, path, body: body, authorized: authorized)
        guard let value = try Wire.decoder.decode(Envelope<Response>.self, from: data).data else { throw APIError.invalidResponse }
        return value
    }

    func sendIgnoringData(_ method: String, _ path: String, body: (any Encodable)? = nil, authorized: Bool = true) async throws {
        _ = try await sendRaw(method, path, body: body, authorized: authorized)
    }

    func sendRaw(_ method: String, _ path: String, body: (any Encodable)?, authorized: Bool) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "api/" + path))
        request.httpMethod = method
        request.setValue(staticAPIKey, forHTTPHeaderField: "STATIC-API-KEY")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Wire.encoder.encode(body)
        }
        guard authorized else { return try await perform(request) }

        guard let current = tokens.load() else { throw APIError.signedOut }
        do {
            return try await perform(request, accessToken: current.accessToken)
        } catch APIError.server(status: 401, _, _) {
            let renewed = try await refresh(replacing: current)
            do {
                return try await perform(request, accessToken: renewed.accessToken)
            } catch APIError.server(status: 401, _, _) {
                tokens.clear()
                throw APIError.signedOut
            }
        }
    }

    private func perform(_ request: URLRequest, accessToken: String? = nil) async throws -> Data {
        var request = request
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? Wire.decoder.decode(ErrorBody.self, from: data)
            throw APIError.server(status: http.statusCode, code: error?.code ?? "", message: error?.message ?? "")
        }
        return data
    }

    /// One refresh at a time: callers that hit 401 together wait for the same new session.
    private func refresh(replacing stale: AuthTokens) async throws -> AuthTokens {
        if let refreshing { return try await refreshing.value }
        if let current = tokens.load(), current.accessToken != stale.accessToken { return current }

        let task = Task { [tokens] in
            do {
                let renewed: AuthTokens = try await self.send("POST", "auth/refresh", body: RefreshBody(refreshToken: stale.refreshToken), authorized: false)
                tokens.save(renewed)
                return renewed
            } catch APIError.server(status: 401, _, _) {
                tokens.clear()
                throw APIError.signedOut
            }
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }
}

private nonisolated struct Envelope<T: Decodable>: Decodable {
    let data: T?
}

private nonisolated struct ErrorBody: Decodable {
    let code: String?
    let message: String?
}

private nonisolated struct Credentials: Encodable { let email: String; let password: String }
private nonisolated struct VerifyEmail: Encodable { let email: String; let otpCode: String }
private nonisolated struct EmailOnly: Encodable { let email: String }
private nonisolated struct EmailLogin: Encodable { let email: String; let password: String; let device: DeviceInfo }
private nonisolated struct AppleLogin: Encodable { let identityToken: String; let authorizationCode: String; let nonce: String; let device: DeviceInfo }
private nonisolated struct GoogleLogin: Encodable { let idToken: String; let nonce: String; let device: DeviceInfo }
private nonisolated struct RefreshBody: Encodable { let refreshToken: String }
