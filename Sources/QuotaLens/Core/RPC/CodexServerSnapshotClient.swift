// Short-lived Codex App Server snapshot reader.
// Used by refresh/startup to pull account and rate-limit data directly from the server.

import Foundation

public struct CodexServerSnapshot: Sendable {
    public let version: String
    public let binaryPath: String
    public let account: AccountReadResult?
    public let accountRawJson: String
    public let rateLimits: RateLimitsReadResult?
    public let rateLimitsRawJson: String
}

public struct CodexServerSnapshotClient: Sendable {
    public static func fetch(customPath: String? = nil, timeoutSeconds: Double = 6.0) throws -> CodexServerSnapshot {
        let lookup = CodexBinaryLocator.inspectBinary(customPath: customPath)
        guard let binaryPath = lookup.binaryPath else {
            throw NSError(
                domain: "CodexServerSnapshotClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: lookup.failureReason ?? L10n.text("未找到 Codex", "Codex was not found")]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["app-server", "--stdio"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let collector = JSONLineCollector()

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try process.run()
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let writer = stdin.fileHandleForWriting
        try writeRequest(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "QuotaLens", "version": AppVersion.marketingVersion],
            "capabilities": [:]
        ], to: writer)
        try writeRequest(id: 2, method: "account/read", params: [:], to: writer)
        try writeRequest(id: 3, method: "account/rateLimits/read", params: [:], to: writer)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if collector.result(for: 2) != nil,
               collector.result(for: 3) != nil {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let accountResult = collector.result(for: 2)
        let rateResult = collector.result(for: 3)

        if accountResult == nil && rateResult == nil {
            let error = collector.error(for: 2) ?? collector.error(for: 3) ?? L10n.text("读取额度超时", "Timed out while reading quota data")
            throw NSError(domain: "CodexServerSnapshotClient", code: -3, userInfo: [NSLocalizedDescriptionKey: error])
        }

        let version = queryVersion(at: binaryPath) ?? "codex (unknown)"

        return CodexServerSnapshot(
            version: version,
            binaryPath: binaryPath,
            account: accountResult.flatMap { decode(AccountReadResult.self, fromJSONObject: $0) },
            accountRawJson: accountResult.map(jsonString) ?? "{}",
            rateLimits: rateResult.flatMap { decode(RateLimitsReadResult.self, fromJSONObject: $0) },
            rateLimitsRawJson: rateResult.map(jsonString) ?? "{}"
        )
    }

    private static func writeRequest(id: Int, method: String, params: [String: Any], to handle: FileHandle) throws {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        var data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, fromJSONObject object: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func queryVersion(at binaryPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

private final class JSONLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var results: [Int: Any] = [:]
    private var errors: [Int: String] = [:]

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            parseLine(line)
        }
    }

    func result(for id: Int) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return results[id]
    }

    func error(for id: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return errors[id]
    }

    private func parseLine(_ data: Data) {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int else {
            return
        }

        if let result = object["result"] {
            results[id] = result
        } else if let error = object["error"] as? [String: Any] {
            errors[id] = (error["message"] as? String) ?? String(describing: error)
        }
    }
}
