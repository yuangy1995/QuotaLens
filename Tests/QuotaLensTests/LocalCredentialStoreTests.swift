import Foundation
import XCTest
@testable import QuotaLens

final class LocalCredentialStoreTests: XCTestCase {
    private struct Secret: Codable, Equatable, Sendable { let token: String }

    func testCiphertextRoundTripPermissionsAndRandomNonce() throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("vault")
        let store = LocalCredentialStore(root: root)
        let value = Secret(token: "fixture-secret-not-a-real-token")
        try store.save(value, id: "one")
        let first = try Data(contentsOf: root.appendingPathComponent("one.qcred"))
        XCTAssertNil(String(data: first, encoding: .utf8))
        XCTAssertFalse(first.range(of: Data(value.token.utf8)) != nil)
        XCTAssertEqual(try store.load(Secret.self, id: "one"), value)
        try store.save(value, id: "one")
        XCTAssertNotEqual(try Data(contentsOf: root.appendingPathComponent("one.qcred")), first)
        for (url, expected) in [(root, 0o700), (root.appendingPathComponent("master.key"), 0o600), (root.appendingPathComponent("one.qcred"), 0o600)] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, expected)
        }
    }

    func testTamperingAndSwappedCiphertextsAreRejected() throws {
        let root = try makeTemporaryDirectory()
        let store = LocalCredentialStore(root: root)
        try store.save(Secret(token: "one"), id: "one")
        try store.save(Secret(token: "two"), id: "two")
        let one = root.appendingPathComponent("one.qcred")
        let two = root.appendingPathComponent("two.qcred")
        let original = try Data(contentsOf: one)
        try original.write(to: two)
        XCTAssertThrowsError(try store.load(Secret.self, id: "two"))
        var corrupted = original
        corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: one)
        XCTAssertThrowsError(try store.load(Secret.self, id: "one"))
    }

    func testMissingOrInvalidKeyNeverRecreatesOrOverwritesCredentials() throws {
        let root = try makeTemporaryDirectory()
        let store = LocalCredentialStore(root: root)
        try store.save(Secret(token: "fixture"), id: "one")
        let original = try Data(contentsOf: root.appendingPathComponent("one.qcred"))
        let key = root.appendingPathComponent("master.key")
        try FileManager.default.removeItem(at: key)
        XCTAssertThrowsError(try store.load(Secret.self, id: "one"))
        XCTAssertThrowsError(try store.save(Secret(token: "replacement"), id: "two"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: key.path))
        try Data(repeating: 0, count: 32).write(to: key)
        XCTAssertThrowsError(try store.save(Secret(token: "replacement"), id: "one"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("one.qcred")), original)
    }

    func testPathsAndSymlinksCannotEscapeVault() throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("vault")
        let store = LocalCredentialStore(root: root)
        XCTAssertThrowsError(try store.save(Secret(token: "fixture"), id: "../outside"))
        let target = parent.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        XCTAssertThrowsError(try store.save(Secret(token: "fixture"), id: "one"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "untouched")
    }

    func testConcurrentStoresSerializeKeyCreationAndWrites() async throws {
        let root = try makeTemporaryDirectory()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask { try LocalCredentialStore(root: root).save(Secret(token: "\(index)"), id: "item-\(index)") }
            }
            try await group.waitForAll()
        }
        for index in 0..<12 {
            XCTAssertEqual(try LocalCredentialStore(root: root).load(Secret.self, id: "item-\(index)").token, "\(index)")
        }
    }

    func testClaudeCacheUsesOnlyEncryptedLocalFiles() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("claude-cache")
        let identity = ClaudeAccountIdentity(accountKey: "fixture-account", confidence: .stableProviderID, aliases: [])
        try ClaudeOAuthCache.save(.init(accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAtMs: 4_000_000_000_000),
            scopes: ["user:profile"], identity: identity, fallbackRefreshToken: "fallback", to: url)
        XCTAssertEqual(ClaudeOAuthCache.load(from: url)?.accessToken, "fixture-access")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        ClaudeOAuthCache.clear(at: url)
        XCTAssertNil(ClaudeOAuthCache.load(from: url))
    }
}
