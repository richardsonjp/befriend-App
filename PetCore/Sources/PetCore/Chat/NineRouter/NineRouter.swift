//
//  NineRouter.swift
//  PetCore
//
//  The user's own model, through 9Router (M37): a local proxy (github.com/decolua/9router) at localhost:20128 that
//  speaks the OpenAI API and routes to the provider the user set up there with their own keys. befriend only talks
//  to that address; what it sends goes on to the chosen provider (or a local model, if 9Router routes to one).
//  Structured answers use `response_format` with the Generable type's own JSON schema.
//

import Foundation
import FoundationModels

public nonisolated struct NineRouter: Sendable {
    public static let defaultBaseURL = URL(string: "http://localhost:20128/v1")!

    public struct Config: Equatable, Sendable {
        public var baseURL: URL
        /// Only when 9Router requires one (REQUIRE_API_KEY); kept in the Keychain, never in settings.
        public var apiKey: String?

        public init(baseURL: URL = NineRouter.defaultBaseURL, apiKey: String? = nil) {
            self.baseURL = baseURL
            self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        }
    }

    /// One chat message, OpenAI style: text, or text with an image (for models that see images).
    public struct Message: Equatable, Sendable {
        public enum Role: String, Sendable { case system, user, assistant }
        public let role: Role
        public let text: String
        /// A PNG, sent as a data URL.
        public let image: Data?

        public init(_ role: Role, _ text: String, image: Data? = nil) {
            self.role = role
            self.text = text
            self.image = image
        }

        var json: [String: Any] {
            guard let image else { return ["role": role.rawValue, "content": text] }
            return ["role": role.rawValue, "content": [
                ["type": "text", "text": text],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64," + image.base64EncodedString()]],
            ]]
        }
    }

    public enum Failure: LocalizedError, Equatable {
        /// Nothing answers at the address: 9Router isn't running (or the address is wrong).
        case unreachable(URL)
        /// 9Router answered with an error: the provider failed, the model is unknown, the key is wrong…
        case provider(String)
        /// An answer that couldn't be read.
        case badReply

        public var errorDescription: String? {
            switch self {
            case .unreachable(let url): "9Router isn't answering at \(url.host() ?? url.absoluteString):\(url.port.map(String.init) ?? "")."
            case .provider(let message): "9Router: \(message)"
            case .badReply: "9Router sent an answer I couldn't read."
            }
        }
    }

    public let config: Config
    let session: URLSession
    /// How long to wait for a first answer (big models can think a while).
    static let timeout: TimeInterval = 120

    public init(_ config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: Models

    /// The models and combos 9Router offers (`/v1/models`), sorted.
    public func models() async throws -> [String] {
        let data = try await send(request("models", body: nil))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { throw Failure.badReply }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: Answers

    /// The whole answer at once.
    public func respond(_ messages: [Message], model: String, maxTokens: Int? = nil) async throws -> String {
        let data = try await send(request("chat/completions", body: body(messages, model: model, maxTokens: maxTokens, stream: false)))
        return try Self.content(of: data)
    }

    /// A structured answer: the type's JSON schema as `response_format`, read back into the type.
    public func respond<T: Generable>(_ messages: [Message], model: String, generating type: T.Type = T.self) async throws -> T {
        try T(try await respond(messages, model: model, schema: T.generationSchema, name: String(describing: T.self)))
    }

    /// A structured answer for a schema built at run time.
    public func respond(_ messages: [Message], model: String, schema: GenerationSchema, name: String = "answer") async throws -> GeneratedContent {
        var body = body(messages, model: model, maxTokens: nil, stream: false)
        let schemaJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema))
        body["response_format"] = ["type": "json_schema", "json_schema": ["name": Self.schemaName(name), "schema": schemaJSON, "strict": true]]
        let text = try Self.content(of: try await send(request("chat/completions", body: body)))
        do { return try GeneratedContent(json: Self.json(in: text)) } catch { throw Failure.badReply }
    }

    /// The answer as it's written: the text so far, growing.
    public func stream(_ messages: [Message], model: String, maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try request("chat/completions", body: body(messages, model: model, maxTokens: maxTokens, stream: true))
                    let (bytes, response) = try await connect(request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw Self.failure(status: (response as? HTTPURLResponse)?.statusCode, body: data)
                    }
                    var text = ""
                    reading: for try await line in bytes.lines {
                        switch try Self.event(line) {
                        case .text(let delta)?:
                            text += delta
                            continuation.yield(text)
                        case .done?: break reading
                        case nil: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Requests

    func body(_ messages: [Message], model: String, maxTokens: Int?, stream: Bool) -> [String: Any] {
        var body: [String: Any] = ["model": model, "messages": messages.map(\.json), "stream": stream]
        if let maxTokens { body["max_tokens"] = maxTokens }
        return body
    }

    func request(_ path: String, body: [String: Any]?) throws -> URLRequest {
        var request = URLRequest(url: config.baseURL.appending(path: path), timeoutInterval: Self.timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let key = config.apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw mapped(error) }
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else { throw Self.failure(status: status, body: data) }
        return data
    }

    private func connect(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do { return try await session.bytes(for: request) } catch { throw mapped(error) }
    }

    /// Can't connect → unreachable; cancelling stays cancelling.
    private func mapped(_ error: Error) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        return error is URLError ? Failure.unreachable(config.baseURL) : error
    }

    // MARK: Reading answers

    /// One server-sent event of a streamed answer.
    enum Event: Equatable {
        case text(String)
        case done
    }

    /// An error answer's message: OpenAI's `{"error": {"message": …}}`, or the body as text.
    static func failure(status: Int?, body: Data) -> Failure {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = (object?["error"] as? [String: Any])?["message"] as? String ?? object?["error"] as? String
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return .provider(trimmed.isEmpty ? "error \(status ?? 0)" : trimmed)
    }

    static func content(of data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = ((object["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw Failure.badReply }
        return content
    }

    /// One server-sent event line: the text it adds, `done` at the end, nil for anything else (comments, roles).
    static func event(_ line: String) throws -> Event? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        if let error = object["error"] {
            throw Failure.provider((error as? [String: Any])?["message"] as? String ?? String(describing: error))
        }
        let delta = ((object["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any]
        return (delta?["content"] as? String).map(Event.text)
    }

    /// The JSON in a reply: some models wrap it in a ```json fence despite the schema.
    static func json(in text: String) -> String {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = text.lastIndex(where: { $0 == "}" || $0 == "]" }), start <= end else { return text }
        return String(text[start...end])
    }

    /// OpenAI allows letters, digits, _ and - in a schema's name.
    static func schemaName(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return clean.isEmpty ? "answer" : String(clean.prefix(64))
    }
}
