// Stable, privacy-preserving account identifiers.

import CryptoKit
import Foundation

public enum AccountIdentityConfidence: String, Codable, Sendable {
    case stableProviderID
    case verifiedEmail
    case provisionalTokenDerived
}

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

enum ProviderAccountAliases {
    enum MigrationError: Error {
        case conflictingIdentity
        case aliasCycle
        case aliasChainTooDeep
    }

    static func resolve(_ key: String, provider: UsageProvider, database: SQLiteDatabase) throws -> String {
        var current = key
        var visited = Set<String>()
        for _ in 0..<8 {
            guard visited.insert(current).inserted else { throw MigrationError.aliasCycle }
            guard let next = try database.stringScalar(
                sql: "SELECT canonical_account_key FROM account_aliases WHERE provider = ? AND legacy_account_key = ?;",
                bindings: [provider.rawValue, current]
            ) else { return current }
            current = next
        }
        if try database.stringScalar(
            sql: "SELECT canonical_account_key FROM account_aliases WHERE provider = ? AND legacy_account_key = ?;",
            bindings: [provider.rawValue, current]
        ) != nil {
            throw MigrationError.aliasChainTooDeep
        }
        return current
    }

    // The caller's transaction also covers provider-specific cached payloads.
    static func migrate(from legacyKey: String, to accountKey: String, provider: UsageProvider, database: SQLiteDatabase) throws {
        guard legacyKey != accountKey else { return }
        let resolved = try resolve(legacyKey, provider: provider, database: database)
        guard resolved == legacyKey || resolved == accountKey else {
            throw MigrationError.conflictingIdentity
        }
        try database.executeUpdate(
            sql: "UPDATE rate_limit_snapshots SET account_key = ? WHERE provider = ? AND account_key = ?;",
            bindings: [accountKey, provider.rawValue, legacyKey]
        )
        try database.executeUpdate(
            sql: "UPDATE account_aliases SET canonical_account_key = ? WHERE provider = ? AND canonical_account_key = ?;",
            bindings: [accountKey, provider.rawValue, legacyKey]
        )
        try database.executeUpdate(
            sql: """
            INSERT INTO account_aliases (provider, legacy_account_key, canonical_account_key, migrated_at)
            VALUES (?, ?, ?, unixepoch())
            ON CONFLICT(provider, legacy_account_key) DO UPDATE SET
                canonical_account_key = excluded.canonical_account_key,
                migrated_at = excluded.migrated_at;
            """,
            bindings: [provider.rawValue, legacyKey, accountKey]
        )
    }
}
