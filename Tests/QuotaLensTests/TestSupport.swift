import Foundation
import XCTest
@testable import QuotaLens

extension XCTestCase {
    func makeTemporaryDirectory(named name: String = "QuotaLensTests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func makeMigratedDatabase(in directory: URL) throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        try SchemaMigrations.migrate(database: database)
        return database
    }

    func overwriteFile(_ url: URL, with text: String, modificationDate: Date? = nil) throws {
        let data = try XCTUnwrap(text.data(using: .utf8))
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        if let modificationDate {
            try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        }
    }

    func appendFile(_ url: URL, with text: String, modificationDate: Date? = nil) throws {
        let data = try XCTUnwrap(text.data(using: .utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
        if let modificationDate {
            try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        }
    }

    func rolloutText(
        sessionId: String,
        timestamp: String = "2026-08-20T12:00:00Z",
        model: String = "gpt-5.4",
        input: Int64,
        cached: Int64 = 0,
        output: Int64,
        parentSessionId: String? = nil,
        agentRole: String? = nil
    ) -> String {
        var source = ""
        if let parentSessionId {
            let role = agentRole ?? "worker"
            source = ",\"source\":{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(parentSessionId)\",\"agent_role\":\"\(role)\"}}}"
        }
        let sessionMeta = "{\"timestamp\":\"\(timestamp)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionId)\",\"cwd\":\"/tmp/QuotaLensFixture\"\(source)}}"
        let context = "{\"timestamp\":\"\(timestamp)\",\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\"}}"
        let usage = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"output_tokens\":\(output)},\"total_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"output_tokens\":\(output)}}}}"
        return [sessionMeta, context, usage].joined(separator: "\n") + "\n"
    }
}
