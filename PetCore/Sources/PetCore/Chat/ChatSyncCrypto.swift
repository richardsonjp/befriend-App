//
//  ChatSyncCrypto.swift
//  PetCore
//
//  End-to-end encryption for chat sync (M23). One random 256-bit key per account encrypts every conversation and
//  file before upload (AES-GCM); the server only ever holds ciphertext. The key lives in the Keychain and reaches a
//  second device only through the Mac's QR code: the code carries a one-time public key and a one-time secret, so
//  whichever device has the key can seal it for the other while the server, which never sees the secret, can
//  neither read it nor slip in a key of its own. All from Apple's CryptoKit.
//

import CryptoKit
import Foundation
import Security

public nonisolated enum ChatCrypto {
    public enum Failure: Error { case malformed, noKey }

    // MARK: Records

    /// Seals a record; the kind and id are bound in, so a blob can't be swapped onto another record.
    static func seal(_ plain: Data, kind: String, id: UUID, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key, authenticating: Data("\(kind)|\(id.uuidString)".utf8)).combined else {
            throw Failure.malformed
        }
        return combined
    }

    static func open(_ sealed: Data, kind: String, id: UUID, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data("\(kind)|\(id.uuidString)".utf8))
    }

    /// Names a key without revealing it, so devices can tell whether they hold the account's key.
    public static func keyID(of key: SymmetricKey) -> String {
        let digest = key.withUnsafeBytes { SHA256.hash(data: Data("befriend-chat-key-id".utf8) + Data($0)) }
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Key exchange (the QR code)

    /// What the Mac's QR code carries: where to meet, its one-time public key, and the one-time secret.
    public struct Invitation: Equatable, Sendable {
        public let exchange: UUID
        public let publicKey: Data
        public let secret: Data

        public var queryItems: [URLQueryItem] {
            [URLQueryItem(name: "x", value: exchange.uuidString),
             URLQueryItem(name: "xp", value: publicKey.base64URL),
             URLQueryItem(name: "xs", value: secret.base64URL)]
        }

        public init(exchange: UUID, publicKey: Data, secret: Data) {
            self.exchange = exchange
            self.publicKey = publicKey
            self.secret = secret
        }

        /// From a scanned befriend:// link; nil when it carries no (or a malformed) invitation.
        public init?(url: URL) {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            guard let exchange = value("x").flatMap(UUID.init(uuidString:)),
                  let publicKey = value("xp").flatMap(Data.init(base64URL:)), publicKey.count == 65,
                  let secret = value("xs").flatMap(Data.init(base64URL:)), secret.count == 32 else { return nil }
            self.init(exchange: exchange, publicKey: publicKey, secret: secret)
        }
    }

    /// One side of an exchange: a fresh key pair, and the invitation's secret.
    public struct Party: Sendable {
        let privateKey: P256.KeyAgreement.PrivateKey
        public var publicKey: Data { privateKey.publicKey.x963Representation }

        public init() {
            privateKey = P256.KeyAgreement.PrivateKey()
        }

        /// The key both sides derive: their key agreement, salted with the secret only the QR code carried.
        func sharedKey(with other: Data, secret: Data, exchange: UUID) throws -> SymmetricKey {
            let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: other)
            return try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
                .hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret,
                                         sharedInfo: Data("befriend-chat-key|\(exchange.uuidString)".utf8), outputByteCount: 32)
        }

        public func sealKey(_ chatKey: SymmetricKey, for other: Data, secret: Data, exchange: UUID) throws -> Data {
            let wrapping = try sharedKey(with: other, secret: secret, exchange: exchange)
            let raw = chatKey.withUnsafeBytes { Data($0) }
            guard let combined = try AES.GCM.seal(raw, using: wrapping, authenticating: Data(exchange.uuidString.utf8)).combined else {
                throw Failure.malformed
            }
            return combined
        }

        /// Opens a key sealed for us; fails if anyone without the secret made it.
        public func openKey(_ sealed: Data, from other: Data, secret: Data, exchange: UUID) throws -> SymmetricKey {
            let wrapping = try sharedKey(with: other, secret: secret, exchange: exchange)
            let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: wrapping, authenticating: Data(exchange.uuidString.utf8))
            guard raw.count == 32 else { throw Failure.malformed }
            return SymmetricKey(data: raw)
        }
    }

    public static func newInvitation(_ party: Party) -> Invitation {
        Invitation(exchange: UUID(), publicKey: party.publicKey, secret: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }
}

/// The account's chat key in the Keychain: this device only, readable after first unlock.
public final class ChatKeyStore: @unchecked Sendable {
    private let service: String
    private let account: String
    /// Tests: no Keychain (unsigned test runners can't use it).
    private let inMemory: Bool
    private var memory: SymmetricKey?

    public init(userID: String, service: String = "com.richardsonjp.befriend.chat-key", inMemory: Bool = false) {
        self.service = service
        self.account = userID
        self.inMemory = inMemory
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func load() -> SymmetricKey? {
        if inMemory { return memory }
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    @discardableResult
    public func save(_ key: SymmetricKey) -> Bool {
        if inMemory {
            memory = key
            return true
        }
        let data = key.withUnsafeBytes { Data($0) }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func clear() {
        memory = nil
        if !inMemory { SecItemDelete(query as CFDictionary) }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
