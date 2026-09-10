//
//  TokenStorage.swift
//  PetCore
//

import Foundation
import os
import Security

/// Where the signed-in session lives. The keychain in the apps; memory in tests and previews.
public protocol TokenStorage: AnyObject {
    func load() -> AuthTokens?
    func save(_ tokens: AuthTokens)
    func clear()
}

/// Data-protection keychain item. Pass the App Group keychain access group on iOS so the widget and intents
/// share the session; readable after first unlock so background refresh works.
public final class KeychainTokenStorage: TokenStorage {
    private static let log = Logger(subsystem: "com.richardsonjp.befriend", category: "keychain")

    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.richardsonjp.befriend.session", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "session",
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func load() -> AuthTokens? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    public func save(_ tokens: AuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Self.log.error("Saving the session failed: \(status)")
        }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

public final class InMemoryTokenStorage: TokenStorage {
    public private(set) var tokens: AuthTokens?

    public init(tokens: AuthTokens? = nil) {
        self.tokens = tokens
    }

    public func load() -> AuthTokens? { tokens }
    public func save(_ tokens: AuthTokens) { self.tokens = tokens }
    public func clear() { tokens = nil }
}
