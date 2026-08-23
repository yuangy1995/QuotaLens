// QuotaLens 本地会话兼容基线扫描器
// 只抽取累计 token 计数字段建立线程基线，不回填账户总账或历史精确用量。

import Foundation

public struct LocalSessionScanner: Sendable {
    /// 扫描 ~/.codex/sessions/ 目录并建立线程累计快照基线。
    /// 历史本地日志不等同于官方 account/usage/read，总账和周期必须来自 App Server 账户接口。
    public static func scanAndSync(
        into repositories: Repositories,
        accountKey: String,
        activeMeterVersionId _: String? = "meter-2026-07-v1",
        deviceId: String = "macOS_local",
        maxFiles: Int = 80,
        resetExistingBaselines: Bool = false
    ) {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let sessionsDir = homeDir.appendingPathComponent(".codex/sessions", isDirectory: true)

        guard fileManager.fileExists(atPath: sessionsDir.path) else {
            return
        }

        if resetExistingBaselines {
            try? repositories.deleteLocalSessionBaselineSnapshots(deviceId: deviceId)
        }

        // 递归检索所有 .jsonl 文件
        guard let enumerator = fileManager.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var jsonlFiles: [(url: URL, mtime: Date)] = []
        for case let fileUrl as URL in enumerator {
            if fileUrl.pathExtension == "jsonl" {
                let attrs = try? fileManager.attributesOfItem(atPath: fileUrl.path)
                let mtime = attrs?[.modificationDate] as? Date ?? Date.distantPast
                jsonlFiles.append((url: fileUrl, mtime: mtime))
            }
        }

        // 按修改时间倒序排列，优先读取最新活跃会话
        jsonlFiles.sort { $0.mtime > $1.mtime }

        var baselineCount = 0

        for item in jsonlFiles.prefix(maxFiles) {
            let fileUrl = item.url
            let filePath = fileUrl.path
            guard let file = fopen(filePath, "r") else { continue }
            defer { fclose(file) }

            var lineBuffer: UnsafeMutablePointer<CChar>? = nil
            var lineCap: Int = 0
            var currentModel: String?
            let sessionId = fileUrl.deletingPathExtension().lastPathComponent

            while true {
                let bytesRead = getline(&lineBuffer, &lineCap, file)
                if bytesRead == -1 { break }
                guard bytesRead > 1, let buffer = lineBuffer else { continue }

                let lineData = Data(bytes: buffer, count: bytesRead)
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                let type = json["type"] as? String ?? ""
                let timestamp = parseTimestamp(json["timestamp"])
                    ?? Int64(item.mtime.timeIntervalSince1970)

                if type == "turn_context" {
                    if let payload = json["payload"] as? [String: Any], let model = payload["model"] as? String {
                        currentModel = model
                    }
                } else if type == "event_msg" {
                    if let payload = json["payload"] as? [String: Any] {
                        if let pType = payload["type"] as? String, pType == "token_count",
                           let info = payload["info"] as? [String: Any] {

                            if let usage = info["total_token_usage"] as? [String: Any] {
                                let inputTokens: Int64 = (usage["input_tokens"] as? Int64) ?? Int64((usage["input_tokens"] as? Int) ?? 0)
                                let cachedTokens: Int64 = (usage["cached_input_tokens"] as? Int64) ?? Int64((usage["cached_input_tokens"] as? Int) ?? 0)
                                let outputTokens: Int64 = (usage["output_tokens"] as? Int64) ?? Int64((usage["output_tokens"] as? Int) ?? 0)
                                var totalTokens: Int64 = (usage["total_tokens"] as? Int64) ?? Int64((usage["total_tokens"] as? Int) ?? 0)
                                if totalTokens == 0 {
                                    totalTokens = inputTokens + cachedTokens + outputTokens
                                }

                                if totalTokens > 0 {
                                    let eventModel = (info["model"] as? String)
                                        ?? (payload["model"] as? String)
                                        ?? currentModel
                                    let canonicalModel = ModelAliasResolver.resolve(rawModel: eventModel)

                                    let snapshot = ThreadUsageSnapshotRecord(
                                        deviceId: deviceId,
                                        observedAt: timestamp,
                                        threadId: sessionId,
                                        modelRaw: eventModel,
                                        modelCanonical: canonicalModel,
                                        reasoningEffort: "medium",
                                        serviceTier: "standard",
                                        inputTokens: inputTokens,
                                        cachedInputTokens: cachedTokens,
                                        outputTokens: outputTokens,
                                        totalTokens: totalTokens,
                                        estimatedCreditsMicros: 0,
                                        rawJson: "{\"source\":\"local_session_baseline\",\"quality\":\"baseline_only\"}"
                                    )
                                    try? repositories.insertThreadUsageSnapshot(snapshot)
                                    baselineCount += 1
                                }
                            }
                        }
                    }
                }
            }

            if let ptr = lineBuffer {
                free(ptr)
            }
        }

        guard baselineCount > 0 else { return }

        let now = Int64(Date().timeIntervalSince1970)
        let auditEvent = QuotaEventRecord(
            eventId: "local_baseline_\(now)",
            occurredAt: now,
            eventType: "local_session_baseline_imported",
            severity: "info",
            limitId: nil,
            oldCycleId: nil,
            newCycleId: nil,
            evidenceJson: "{\"baselineSnapshots\":\(baselineCount),\"quality\":\"baseline_only\",\"note\":\"本地历史日志只用于建立后续差分基线，不回填账户总账或历史精确用量\"}"
        )
        try? repositories.insertQuotaEvent(auditEvent)
    }

    private static func parseTimestamp(_ value: Any?) -> Int64? {
        if let int = value as? Int64 {
            return normalizeEpochSeconds(int)
        }
        if let int = value as? Int {
            return normalizeEpochSeconds(Int64(int))
        }
        if let double = value as? Double {
            return normalizeEpochSeconds(Int64(double))
        }
        if let number = value as? NSNumber {
            return normalizeEpochSeconds(number.int64Value)
        }
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        if let numeric = Int64(string) {
            return normalizeEpochSeconds(numeric)
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return Int64(date.timeIntervalSince1970)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string).map { Int64($0.timeIntervalSince1970) }
    }

    private static func normalizeEpochSeconds(_ value: Int64) -> Int64 {
        value > 10_000_000_000 ? value / 1_000 : value
    }
}
