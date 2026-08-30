// Stable, privacy-preserving account identifiers.

import CryptoKit
import Foundation

public struct AccountIdentity: Sendable {
    private static let unknownSessionIdentifier = UUID().uuidString

    public static func stableAccountKey(from identifier: String) -> String {
        "acc_\(shortHash(identifier, length: 16))"
    }

    public static func emailHash(from identifier: String) -> String {
        sha256Hex(normalized(identifier))
    }

    public static func temporaryUnknownIdentifier() -> String {
        "unknown_\(unknownSessionIdentifier)"
    }

    private static func shortHash(_ value: String, length: Int) -> String {
        String(sha256Hex(normalized(value)).prefix(length))
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
