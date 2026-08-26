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
        let shortPseudoCanonical = paths.sessionsURL.appendingPathComponent("rollout-2026-08-20T12-00-00-abcdef12.jsonl")
        let canonical = paths.sessionsURL.appendingPathComponent(
            "rollout-2026-08-20T12-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
        )
        let structured = paths.sessionsURL.appendingPathComponent("custom-name.jsonl")
        try overwriteFile(ignored, with: "{\"message\":\"has-dash-but-no-rollout-shape\"}\n")
        try overwriteFile(shortPseudoCanonical, with: "{\"message\":\"short-id-is-not-canonical\"}\n")
        try overwriteFile(canonical, with: "{\"message\":\"canonical-name-is-enough\"}\n")
        try overwriteFile(structured, with: "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":1}}}}\n")

        let outcome = CodexRolloutScanner.scan(paths: paths, scanArchived: false)
        XCTAssertEqual(outcome.active, .success)
        XCTAssertEqual(Set(outcome.sources.map(\.fileURL.lastPathComponent)), [
            "rollout-2026-08-20T12-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl",
            "custom-name.jsonl"
        ])
    }

    func testNonCanonicalJSONLProbeCoversDeepMetadataAndReportsMisses() throws {
        let root = try makeTemporaryDirectory(named: "RolloutScannerDeepProbe")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)

        let validRollout = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":1}}}}\n"
        let afterTwentyOne = paths.sessionsURL.appendingPathComponent("after-line-21.jsonl")
        try overwriteFile(
            afterTwentyOne,
            with: Array(repeating: "{\"type\":\"metadata\"}", count: 25).joined(separator: "\n") + "\n" + validRollout
        )

        let after64KB = paths.sessionsURL.appendingPathComponent("after-64kb.jsonl")
        let largeMetadata = "{\"type\":\"metadata\",\"padding\":\"\(String(repeating: "x", count: 70 * 1024))\"}\n"
        try overwriteFile(after64KB, with: largeMetadata + validRollout)

        let damagedFirst = paths.sessionsURL.appendingPathComponent("damaged-first.jsonl")
        try overwriteFile(damagedFirst, with: "{not-json\n" + validRollout)

        let truncatedUnicode = paths.sessionsURL.appendingPathComponent("truncated-unicode-window.jsonl")
        let probeLimit = 1024 * 1024
        let paddingCount = probeLimit - validRollout.utf8.count - 1
        try overwriteFile(
            truncatedUnicode,
            with: validRollout + String(repeating: "x", count: paddingCount) + "你"
        )

        let outsideWindow = paths.sessionsURL.appendingPathComponent("outside-window.jsonl")
        try overwriteFile(
            outsideWindow,
            with: Array(repeating: "{\"type\":\"metadata\"}", count: 200).joined(separator: "\n") + "\n" + validRollout
        )

        let outcome = CodexRolloutScanner.scan(paths: paths, scanArchived: false)
        XCTAssertEqual(outcome.active, .success)
        XCTAssertEqual(Set(outcome.sources.map(\.fileURL.lastPathComponent)), [
            "after-line-21.jsonl",
            "after-64kb.jsonl",
            "damaged-first.jsonl",
            "truncated-unicode-window.jsonl"
        ])
        XCTAssertEqual(outcome.diagnostics.map(\.fileURL.lastPathComponent), ["outside-window.jsonl"])
        XCTAssertEqual(outcome.diagnostics.first?.code, "non_rollout_jsonl_probe_miss")
    }

    func testPerFileProbeFailureMarksRootIncomplete() throws {
        let root = try makeTemporaryDirectory(named: "RolloutScannerFileFailure")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        let candidate = paths.sessionsURL.appendingPathComponent("candidate.jsonl")
        try overwriteFile(candidate, with: "{}\n")

        let outcome = CodexRolloutScanner.scan(
            paths: paths,
            scanArchived: false,
            enumeratorFactory: nil,
            fileProbe: { fileURL, _ in
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EACCES),
                    userInfo: [NSFilePathErrorKey: fileURL.path]
                )
            }
        )

        if case .failed(let message) = outcome.active {
            XCTAssertTrue(message.contains(candidate.path))
        } else {
            XCTFail("Expected per-file failure to mark the root incomplete, got \(outcome.active)")
        }
        XCTAssertTrue(outcome.sources.isEmpty)
        XCTAssertFalse(outcome.active.allowsTombstone)
    }

    func testEnumeratorUnavailableMarksBothExistingRootsFailed() throws {
        let root = try makeTemporaryDirectory(named: "RolloutScannerBothRootsUnavailable")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.archivedSessionsURL, withIntermediateDirectories: true)

        let outcome = CodexRolloutScanner.scan(
            paths: paths,
            scanArchived: true,
            enumeratorFactory: { _, _, _, _ in nil }
        )

        XCTAssertEqual(outcome.active, .failed("Enumerator unavailable"))
        XCTAssertEqual(outcome.archived, .failed("Enumerator unavailable"))
        XCTAssertTrue(outcome.sources.isEmpty)
    }

    func testArchivedPermissionFailureDoesNotAffectMissingActiveRoot() throws {
        let root = try makeTemporaryDirectory(named: "RolloutScannerArchivedPermission")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(
            at: paths.archivedSessionsURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: paths.archivedSessionsURL.path
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: paths.archivedSessionsURL.path
            )
        }
        if FileManager.default.isReadableFile(atPath: paths.archivedSessionsURL.path) {
            throw XCTSkip("Current filesystem still reports chmod 000 test directory as readable.")
        }

        let outcome = CodexRolloutScanner.scan(paths: paths, scanArchived: true)
        XCTAssertEqual(outcome.active, .notFound)
        XCTAssertEqual(outcome.archived, .inaccessible)
        XCTAssertFalse(outcome.archived.allowsTombstone)
    }

    func testRootStatusesRemainIndependentWhenArchivedEnumeratorIsUnavailable() throws {
        let root = try makeTemporaryDirectory(named: "RolloutScannerIndependentRoots")
        let paths = CodexHistoryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.archivedSessionsURL, withIntermediateDirectories: true)
        let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let activeFile = paths.sessionsURL.appendingPathComponent(
            "rollout-2026-08-20T12-00-00-\(sessionID).jsonl"
        )
        try overwriteFile(activeFile, with: "{}\n")

        let outcome = CodexRolloutScanner.scan(
            paths: paths,
            scanArchived: true,
            enumeratorFactory: { directoryURL, keys, options, errorHandler in
                guard directoryURL == paths.sessionsURL else { return nil }
                return FileManager.default.enumerator(
                    at: directoryURL,
                    includingPropertiesForKeys: keys,
                    options: options,
                    errorHandler: errorHandler
                )
            }
        )

        XCTAssertEqual(outcome.active, .success)
        XCTAssertEqual(outcome.archived, .failed("Enumerator unavailable"))
        XCTAssertEqual(outcome.sources.map(\.sessionId), [sessionID])
    }
}
