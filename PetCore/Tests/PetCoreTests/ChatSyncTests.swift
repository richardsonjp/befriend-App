import CryptoKit
import Foundation
import Testing
@testable import PetCore

struct ChatCryptoTests {
    @Test func recordsRoundTripAndStayBoundToTheirId() throws {
        let key = SymmetricKey(size: .bits256)
        let id = UUID()
        let sealed = try ChatCrypto.seal(Data("hello".utf8), kind: "conversation", id: id, key: key)
        #expect(try ChatCrypto.open(sealed, kind: "conversation", id: id, key: key) == Data("hello".utf8))
        #expect(throws: (any Error).self) { try ChatCrypto.open(sealed, kind: "conversation", id: UUID(), key: key) }
        #expect(throws: (any Error).self) { try ChatCrypto.open(sealed, kind: "conversation", id: id, key: SymmetricKey(size: .bits256)) }
    }

    @Test func theKeyCrossesOnlyWithTheQRSecret() throws {
        let mac = ChatCrypto.Party(), phone = ChatCrypto.Party()
        let invitation = ChatCrypto.newInvitation(mac)
        let chatKey = SymmetricKey(size: .bits256)
        let sealed = try phone.sealKey(chatKey, for: invitation.publicKey, secret: invitation.secret, exchange: invitation.exchange)
        let opened = try mac.openKey(sealed, from: phone.publicKey, secret: invitation.secret, exchange: invitation.exchange)
        #expect(ChatCrypto.keyID(of: opened) == ChatCrypto.keyID(of: chatKey))

        // The server has everything but the secret: it can't read the key, nor make one the Mac would accept.
        let server = ChatCrypto.Party()
        let wrongSecret = Data(repeating: 7, count: 32)
        #expect(throws: (any Error).self) {
            try server.openKey(sealed, from: invitation.publicKey, secret: wrongSecret, exchange: invitation.exchange)
        }
        let forged = try server.sealKey(SymmetricKey(size: .bits256), for: invitation.publicKey, secret: wrongSecret, exchange: invitation.exchange)
        #expect(throws: (any Error).self) {
            try mac.openKey(forged, from: server.publicKey, secret: invitation.secret, exchange: invitation.exchange)
        }
    }

    @Test func invitationsTravelInALink() throws {
        let invitation = ChatCrypto.newInvitation(ChatCrypto.Party())
        var components = URLComponents(string: "befriend://chatsync")!
        components.queryItems = invitation.queryItems
        #expect(ChatCrypto.Invitation(url: components.url!) == invitation)
        #expect(ChatCrypto.Invitation(url: URL(string: "befriend://pair?code=abc")!) == nil)
    }
}

/// The sync server as the backend implements it: stores sealed blobs, last writer wins, a sequence to pull after.
nonisolated final class FakeSyncServer: @unchecked Sendable {
    static let shared = FakeSyncServer()
    private let lock = NSLock()
    private var keyID: String?
    private var records: [String: [String: Any]] = [:]
    private var seq: Int64 = 0
    private var exchanges: [String: [String: String]] = [:]
    private(set) var blobs: [Data] = []

    var debugExchanges: [String: [String: String]] { lock.withLock { exchanges.mapValues { $0.mapValues { String($0.prefix(8)) } } } }

    func reset() {
        lock.withLock {
            keyID = nil
            records = [:]
            seq = 0
            exchanges = [:]
            blobs = []
        }
    }

    func respond(_ request: URLRequest, body: Data?) -> (Int, Data) {
        lock.withLock {
            let path = request.url!.path.replacingOccurrences(of: "/api/chat-sync/", with: "")
            let parts = path.split(separator: "/").map(String.init)
            let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            func ok(_ data: Any) -> (Int, Data) { (200, try! JSONSerialization.data(withJSONObject: ["data": data])) }
            func fail(_ status: Int, _ code: String) -> (Int, Data) { (status, Data(#"{"code":"\#(code)","message":"\#(code)"}"#.utf8)) }
            switch (request.httpMethod!, parts.first) {
            case ("GET", "key"): return ok(["key_id": keyID as Any])
            case ("PUT", "key"):
                let id = json["key_id"] as! String
                if let keyID, keyID != id { return fail(409, "CHAT_KEY_MISMATCH") }
                keyID = id
                return ok([:])
            case ("GET", "records"):
                let after = Int64(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "after" }!.value!)!
                let page = records.values.filter { ($0["seq"] as! Int64) > after }.sorted { ($0["seq"] as! Int64) < ($1["seq"] as! Int64) }
                return ok(["records": page, "next": page.last?["seq"] as? Int64 ?? after, "more": false])
            case ("PUT", "records"):
                let key = parts[1] + "|" + parts[2]
                let modified = json["modified_at"] as! String
                if let existing = records[key]?["modified_at"] as? String, existing > modified { return ok(["seq": seq, "applied": false]) }
                seq += 1
                if let blob = json["blob"] as? String { blobs.append(Data(base64Encoded: blob)!) }
                records[key] = ["kind": parts[1], "id": parts[2], "seq": seq, "modified_at": modified,
                                "deleted": json["deleted"] as! Bool, "blob": json["blob"] ?? NSNull()]
                return ok(["seq": seq, "applied": true])
            case ("PUT", "exchanges"):
                var exchange = exchanges[parts[1]] ?? [:]
                for (field, value) in json { if let value = value as? String, !value.isEmpty { exchange[field] = value } }
                exchanges[parts[1]] = exchange
                return ok([:])
            case ("GET", "exchanges"):
                guard let exchange = exchanges[parts[1]] else { return fail(404, "CHAT_EXCHANGE_NOT_FOUND") }
                return ok(exchange)
            default:
                return fail(404, "NOT_FOUND")
            }
        }
    }
}

nonisolated final class FakeSyncProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let (status, data) = FakeSyncServer.shared.respond(request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor @Suite(.serialized)
struct ChatSyncTests {
    final class Device {
        let library: ChatLibrary
        let sync: ChatSync
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        @MainActor init() {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FakeSyncProtocol.self]
            let api = APIClient(baseURL: URL(string: "https://api.test")!, staticAPIKey: "static",
                                tokens: InMemoryTokenStorage(tokens: AuthTokens(accessToken: "a", refreshToken: "r", deviceId: "d")),
                                session: URLSession(configuration: configuration))
            library = ChatLibrary(root: folder)
            sync = ChatSync(library: library, api: api, userID: "u1", folder: folder, keys: ChatKeyStore(userID: "u1", inMemory: true))
        }
    }

    private func settle(_ device: Device, until done: () -> Bool = { false }) async throws {
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(20))
            if done() { return }
            if case .synced = device.sync.status, !done() { continue }
        }
    }

    @Test func pairThenConversationsFlowBothWays() async throws {
        FakeSyncServer.shared.reset()
        let phone = Device(), mac = Device()

        // The iPhone chats first and makes the account's key.
        var chat = Conversation()
        chat.messages = [ChatMessage(role: .user, text: "When is the launch?"), ChatMessage(role: .friend, text: "May 3rd.")]
        phone.library.save(chat)
        phone.sync.start()
        try await settle(phone) { if case .synced = phone.sync.status { true } else { false } }
        #expect(phone.sync.hasKey)
        // The server only ever saw ciphertext.
        #expect(!FakeSyncServer.shared.blobs.contains { String(decoding: $0, as: UTF8.self).contains("launch") })

        // The Mac has no key yet: it must pair.
        mac.sync.start()
        try await settle(mac) { mac.sync.status == .needsKey }
        #expect(mac.sync.status == .needsKey && mac.library.conversations.isEmpty)

        // The Mac shows its code; the iPhone scans it and sends the key sealed for the Mac.
        let invitation = mac.sync.invite()
        phone.sync.accept(invitation)
        try await settle(mac) { !mac.library.conversations.isEmpty }
        #expect(mac.library.conversations.first?.messages.map(\.text) == ["When is the launch?", "May 3rd."])

        // A reply on the Mac reaches the iPhone.
        var continued = try #require(mac.library.conversation(chat.id))
        continued.messages.append(ChatMessage(role: .user, text: "And the budget?"))
        mac.library.save(continued)
        try await settle(mac) { FakeSyncServer.shared.blobs.count >= 3 }
        phone.sync.sync()
        try await settle(phone) { phone.library.conversation(chat.id)?.messages.count == 3 }
        #expect(phone.library.conversation(chat.id)?.messages.last?.text == "And the budget?")

        // Deleting on the iPhone deletes on the Mac.
        phone.library.delete(conversation: chat.id)
        try await Task.sleep(for: .seconds(2.3)) // the upload waits a moment for more changes
        try await settle(phone) { if case .synced = phone.sync.status { true } else { false } }
        mac.sync.sync()
        try await settle(mac) { mac.library.conversation(chat.id) == nil }
        #expect(mac.library.conversation(chat.id) == nil)
    }

    @Test func filesSyncWithoutEmbeddingsAndGetThemBack() async throws {
        FakeSyncServer.shared.reset()
        let phone = Device(), mac = Device()
        phone.sync.start()
        try await settle(phone) { phone.sync.hasKey }
        phone.library.add(text: "The launch moved to May third.", name: "Notes", scope: .conversation(UUID()))
        try await settle(phone) { !phone.library.documents.isEmpty }
        try await Task.sleep(for: .seconds(2.3))
        try await settle(phone) { if case .synced = phone.sync.status { true } else { false } }

        let invitation = mac.sync.invite()
        phone.sync.accept(invitation)
        try await settle(mac) { !mac.library.documents.isEmpty }
        let document = try #require(mac.library.documents.first)
        #expect(document.name == "Notes" && document.passages.first?.text == "The launch moved to May third.")
        #expect(document.passages.first?.vector != nil || Retriever.embed("x") == nil) // re-embedded here
    }
}

struct APIPathTests {
    @Test func queriesStayQueries() {
        let base = URL(string: "https://api.test")!
        #expect(APIClient.url(base, "chat-sync/records?after=3&limit=100").absoluteString == "https://api.test/api/chat-sync/records?after=3&limit=100")
        #expect(APIClient.url(base, "friend").absoluteString == "https://api.test/api/friend")
    }
}
