//
//  ChatSync.swift
//  PetCore
//
//  Keeps chats in step between the Mac and the iPhone through the befriend server (M23), end-to-end encrypted:
//  every conversation and file goes up sealed with the account's chat key (ChatCrypto) and comes down the same way.
//  The newer copy of a record wins. The key itself only moves through the Mac's QR code.
//

import CryptoKit
import Foundation
import Observation
import os

// MARK: API

nonisolated struct ChatKeyState: Codable { let keyId: String? }

nonisolated struct ChatRecordWire: Codable {
    let kind: String
    let id: UUID
    let seq: Int64
    let modifiedAt: Date
    let deleted: Bool
    let blob: String?
}

nonisolated struct ChatRecordPage: Codable {
    let records: [ChatRecordWire]
    let next: Int64
    let more: Bool
}

nonisolated struct ChatRecordUpload: Encodable {
    let modifiedAt: String
    let deleted: Bool
    let blob: String?
}

nonisolated struct ChatRecordUploaded: Codable {
    let seq: Int64
    let applied: Bool
}

nonisolated struct ChatExchangeState: Codable {
    var macPublic: String?
    var phonePublic: String?
    var sealedForMac: String?
    var sealedForPhone: String?
}

extension APIClient {
    func chatKey() async throws -> ChatKeyState { try await send("GET", "chat-sync/key") }
    func registerChatKey(_ id: String) async throws { try await sendIgnoringData("PUT", "chat-sync/key", body: ChatKeyState(keyId: id)) }
    func chatRecords(after: Int64) async throws -> ChatRecordPage { try await send("GET", "chat-sync/records?after=\(after)&limit=100") }
    func uploadChatRecord(_ kind: String, _ id: UUID, _ record: ChatRecordUpload) async throws -> ChatRecordUploaded {
        try await send("PUT", "chat-sync/records/\(kind)/\(id.uuidString.lowercased())", body: record)
    }
    func chatExchange(_ id: UUID) async throws -> ChatExchangeState { try await send("GET", "chat-sync/exchanges/\(id.uuidString.lowercased())") }
    func updateChatExchange(_ id: UUID, _ state: ChatExchangeState) async throws {
        try await sendIgnoringData("PUT", "chat-sync/exchanges/\(id.uuidString.lowercased())", body: state)
    }
}

// MARK: Engine

@MainActor @Observable
public final class ChatSync {
    private nonisolated static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "chat-sync")

    public enum Status: Equatable {
        case starting
        /// This device has no key yet (another device made one): pair through the Mac's QR code.
        case needsKey
        case syncing
        case synced(Date)
        case offline(String)
    }

    public private(set) var status = Status.starting
    /// On the Mac: the QR code's invitation while it's shown.
    public private(set) var invitation: ChatCrypto.Invitation?

    private let library: ChatLibrary
    private let api: APIClient
    private let keys: ChatKeyStore
    private let stateFile: URL
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var state: SavedState
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var inviting: Task<Void, Never>?

    /// What sync remembers between launches: how far it has read, and what's still to upload.
    struct SavedState: Codable {
        var after: Int64 = 0
        var pending: [String: Date] = [:] // "kind|id" → when it changed; deletions carry a "-" prefix
        var seeded = false
    }

    public init(library: ChatLibrary, api: APIClient, userID: String, folder: URL, keys: ChatKeyStore? = nil) {
        self.library = library
        self.api = api
        self.keys = keys ?? ChatKeyStore(userID: userID)
        self.stateFile = folder.appending(path: "sync-\(ChatSync.tag(userID)).json")
        self.state = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) } ?? SavedState()
        library.onChange = { [weak self] change in self?.record(change) }
    }

    nonisolated static func tag(_ userID: String) -> String {
        SHA256.hash(data: Data(userID.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public var hasKey: Bool { key != nil }

    /// Sets up the key (making the account's first one if nobody has), then syncs. Safe to call often.
    public func start() {
        sync()
    }

    /// Pull then push; if called while running, runs once more after.
    public func sync() {
        guard running == nil else { return again = true }
        running = Task {
            await run()
            running = nil
            if again {
                again = false
                sync()
            }
        }
    }

    /// Signing out: the library is wiped, so this device forgets how far it had read and pulls everything again at
    /// the next sign-in. The key stays in the Keychain for this account.
    public func stop() {
        running?.cancel()
        inviting?.cancel()
        debounce?.cancel()
        library.onChange = { _ in }
        invitation = nil
        try? FileManager.default.removeItem(at: stateFile)
    }

    private func record(_ change: ChatLibrary.Change) {
        state.pending[(change.deleted ? "-" : "") + change.kind.rawValue + "|" + change.id.uuidString] = change.at
        saveState()
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            sync()
        }
    }

    private func run() async {
        if key == nil {
            guard await setUpKey() else { return }
        }
        status = .syncing
        do {
            if !state.seeded {
                for change in library.allChanges { record(change) }
                state.seeded = true
                saveState()
            }
            try await pull()
            try await push()
            status = .synced(.now)
        } catch {
            Self.log.error("Chat sync failed: \(String(describing: error), privacy: .public)")
            status = .offline("Couldn't sync chats. They'll sync when you're back online.")
        }
    }

    /// Finds or makes the account's key. False when this device must pair first.
    private func setUpKey() async -> Bool {
        do {
            let server = try await api.chatKey().keyId
            if let local = keys.load() {
                let id = ChatCrypto.keyID(of: local)
                if server == nil { try await api.registerChatKey(id) }
                if server == nil || server == id {
                    key = local
                    return true
                }
            } else if server == nil {
                let fresh = SymmetricKey(size: .bits256)
                try await api.registerChatKey(ChatCrypto.keyID(of: fresh))
                keys.save(fresh)
                key = fresh
                return true
            }
            status = .needsKey
            return false
        } catch APIError.server(_, "CHAT_KEY_MISMATCH", _) {
            status = .needsKey // another device registered first
            return false
        } catch {
            status = .offline("Couldn't reach befriend to sync chats.")
            return false
        }
    }

    private func pull() async throws {
        guard let key else { return }
        var more = true
        while more {
            let page = try await api.chatRecords(after: state.after)
            for record in page.records {
                guard let kind = ChatLibrary.RecordKind(rawValue: record.kind) else { continue }
                // The newer copy wins; our own uploads come back no newer than what's here, and are skipped.
                if let local = library.modifiedAt(kind, record.id), record.modifiedAt <= local { continue }
                if record.deleted {
                    library.removeRemote(kind, record.id)
                } else if let blob = record.blob.flatMap({ Data(base64Encoded: $0) }) {
                    do {
                        let plain = try ChatCrypto.open(blob, kind: kind.rawValue, id: record.id, key: key)
                        try await library.applyRemote(kind, plain)
                    } catch {
                        Self.log.error("A synced \(kind.rawValue, privacy: .public) couldn't be opened: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            state.after = max(state.after, page.next)
            more = page.more && !page.records.isEmpty
            saveState()
        }
    }

    private func push() async throws {
        guard let key else { return }
        for (entry, at) in state.pending.sorted(by: { $0.value < $1.value }) {
            let deleted = entry.hasPrefix("-")
            let parts = entry.drop(while: { $0 == "-" }).split(separator: "|")
            guard parts.count == 2, let kind = ChatLibrary.RecordKind(rawValue: String(parts[0])), let id = UUID(uuidString: String(parts[1])) else {
                state.pending[entry] = nil
                continue
            }
            let upload: ChatRecordUpload
            if !deleted, let plain = try library.payload(kind, id) {
                let sealed = try ChatCrypto.seal(plain, kind: kind.rawValue, id: id, key: key)
                upload = ChatRecordUpload(modifiedAt: Self.stamp(library.modifiedAt(kind, id) ?? at), deleted: false,
                                          blob: sealed.base64EncodedString())
            } else {
                upload = ChatRecordUpload(modifiedAt: Self.stamp(at), deleted: true, blob: nil)
            }
            do {
                _ = try await api.uploadChatRecord(kind.rawValue, id, upload)
            } catch APIError.server(_, "CHAT_RECORD_TOO_LARGE", _) {
                Self.log.notice("A \(kind.rawValue, privacy: .public) is too big to sync; it stays on this device")
            }
            state.pending[entry] = nil
            saveState()
        }
    }

    private nonisolated static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    private func saveState() {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }

    // MARK: Pairing the key

    /// The Mac: shows a QR code and waits for the iPhone. Whoever has the key seals it for the other.
    public func invite() -> ChatCrypto.Invitation {
        if let invitation { return invitation }
        let party = ChatCrypto.Party()
        let invitation = ChatCrypto.newInvitation(party)
        self.invitation = invitation
        inviting = Task { await host(invitation, party: party) }
        return invitation
    }

    /// The Mac, after signing in with a QR code that also carried an invitation: pick up the key the iPhone sealed.
    public func resume(_ invitation: ChatCrypto.Invitation, party: ChatCrypto.Party) {
        self.invitation = invitation
        inviting?.cancel()
        inviting = Task { await host(invitation, party: party) }
    }

    public func stopInviting() {
        inviting?.cancel()
        invitation = nil
    }

    private func host(_ invitation: ChatCrypto.Invitation, party: ChatCrypto.Party) async {
        defer { if self.invitation == invitation { self.invitation = nil } }
        do {
            try await api.updateChatExchange(invitation.exchange, ChatExchangeState(macPublic: invitation.publicKey.base64EncodedString()))
            let deadline = Date.now.addingTimeInterval(15 * 60)
            while !Task.isCancelled, Date.now < deadline {
                try? await Task.sleep(for: .seconds(2))
                guard let exchange = try? await api.chatExchange(invitation.exchange),
                      let phone = exchange.phonePublic.flatMap({ Data(base64Encoded: $0) }) else { continue }
                if let sealed = exchange.sealedForMac.flatMap({ Data(base64Encoded: $0) }) {
                    let received = try party.openKey(sealed, from: phone, secret: invitation.secret, exchange: invitation.exchange)
                    adopt(received)
                    return
                }
                if let key, exchange.sealedForPhone == nil {
                    let sealed = try party.sealKey(key, for: phone, secret: invitation.secret, exchange: invitation.exchange)
                    try await api.updateChatExchange(invitation.exchange, ChatExchangeState(sealedForPhone: sealed.base64EncodedString()))
                    return
                }
            }
        } catch {
            Self.log.error("Pairing chat sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The iPhone: answers a scanned code. Sends its key if it has one, else waits for the Mac's.
    public func accept(_ invitation: ChatCrypto.Invitation) {
        let party = ChatCrypto.Party()
        inviting?.cancel()
        inviting = Task {
            do {
                var answer = ChatExchangeState(phonePublic: party.publicKey.base64EncodedString())
                if let key {
                    answer.sealedForMac = try party.sealKey(key, for: invitation.publicKey, secret: invitation.secret,
                                                            exchange: invitation.exchange).base64EncodedString()
                }
                try await api.updateChatExchange(invitation.exchange, answer)
                guard key == nil else { return }
                let deadline = Date.now.addingTimeInterval(5 * 60)
                while !Task.isCancelled, Date.now < deadline {
                    try? await Task.sleep(for: .seconds(2))
                    guard let sealed = (try? await api.chatExchange(invitation.exchange))?.sealedForPhone.flatMap({ Data(base64Encoded: $0) }) else { continue }
                    adopt(try party.openKey(sealed, from: invitation.publicKey, secret: invitation.secret, exchange: invitation.exchange))
                    return
                }
            } catch {
                Self.log.error("Accepting chat sync failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A key from the other device: keep it and sync everything, re-uploading what was made here before.
    private func adopt(_ received: SymmetricKey) {
        keys.save(received)
        key = received
        state.after = 0
        state.seeded = false
        saveState()
        sync()
    }
}
