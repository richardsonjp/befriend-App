//
//  Nonce.swift
//  PetCore
//

import CryptoKit
import Foundation

/// Sign-in nonces: Apple gets `sha256(raw)` in the request and the backend checks the raw value; Google gets the
/// raw value.
public nonisolated enum Nonce {
    /// 32 random bytes as hex, from the system CSPRNG.
    public static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
