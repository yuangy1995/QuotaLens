import Foundation
import XCTest
@testable import QuotaLens

final class CodexRolloutScannerTests: XCTestCase {
    func testRootScanStatusesDistinguishMissingDisabledInaccessibleAndEnumeratorFailure() throws {
        let root = try makeTemporaryDirectory(named: "RolloutScannerStatuses")
        let paths = CodexHistoryPaths(rootURL: root)

        var missing = CodexRolloutScanner.scan(paths: paths, scanArchived: false)
        XCTAssertEqual(missing.active, .notFound)
        XCTAssertEqual(missing.archived, .disabled)

        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let inaccessibleRoot = try makeTemporaryDirectory(named: "RolloutScannerInaccessible")
        let inaccessiblePaths = CodexHistoryPaths(rootURL: inaccessibleRoot)
        try FileManager.default.createDirectory(at: inaccessiblePaths.sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: inaccessiblePaths.sessionsURL.path
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: inaccessiblePaths.sessionsURL.path
            )
        }
        let inaccessible = CodexRolloutScanner.scan(paths: inaccessiblePaths, scanArchived: false)
        if FileManager.default.isReadableFile(atPath: inaccessiblePaths.sessionsURL.path) {
            throw XCTSkip("Current filesystem still reports chmod 000 test directory as readable.")
        }
        XCTAssertEqual(inaccessible.active, .inaccessible)

        let failed = CodexRolloutScanner.scan(
            paths: paths,
            scanArchived: false,
            enumeratorFactory: { directoryURL, keys, options, errorHandler in
                _ = errorHandler?(
                    directoryURL.appendingPathComponent("blocked"),
                    NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                )
                return FileManager.default.enumerator(
                    at: directoryURL,
                    includingPropertiesForKeys: keys,
                    options: options
                )
            }
        )
        if case .failed = failed.active {
            // expected
        } else {
            XCTFail("Expected failed active scan, got \(failed.active)")
        }

        missing = CodexRolloutScanner.scan(paths: paths, scanArchived: true)
        XCTAssertEqual(missing.active, .success)
        XCTAssertEqual(missing.archived, .notFound)
    }

    func testScannerOnlyAcceptsCanonicalRolloutsOrValidRolloutStructure() throws {
        let root = try makeTemporaryDirectory(named: "RolloutScannerFiltering")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)

        let ignored = paths.sessionsURL.appendingPathComponent("not-a-rollout-2026-08-20.jsonl")
        let canonical = paths.sessionsURL.appendingPathComponent("rollout-2026-08-20T12-00-00-abcdef12.jsonl")
        let structured = paths.sessionsURL.appendingPathComponent("custom-name.jsonl")
        try overwriteFile(ignored, with: "{\"message\":\"has-dash-but-no-rollout-shape\"}\n")
        try overwriteFile(canonical, with: "{\"message\":\"canonical-name-is-enough\"}\n")
        try overwriteFile(structured, with: "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":1}}}}\n")

        let outcome = CodexRolloutScanner.scan(paths: paths, scanArchived: false)
        XCTAssertEqual(outcome.active, .success)
        XCTAssertEqual(Set(outcome.sources.map(\.fileURL.lastPathComponent)), [
            "rollout-2026-08-20T12-00-00-abcdef12.jsonl",
            "custom-name.jsonl"
        ])
    }
}
