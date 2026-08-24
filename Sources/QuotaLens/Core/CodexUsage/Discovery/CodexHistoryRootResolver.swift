// QuotaLens Codex 历史目录解析器与文件源标识符

import Foundation

public struct CodexHistoryPaths: Sendable {
    public let rootURL: URL
    public let sessionsURL: URL
    public let archivedSessionsURL: URL
    public let sessionIndexURL: URL
    public let stateDbURL: URL
    public let stateDbCandidateURLs: [URL]

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        self.archivedSessionsURL = rootURL.appendingPathComponent("archived_sessions", isDirectory: true)
        self.sessionIndexURL = rootURL.appendingPathComponent("session_index.jsonl")
        self.stateDbCandidateURLs = [
            rootURL.appendingPathComponent("sqlite", isDirectory: true).appendingPathComponent("state_5.sqlite"),
            rootURL.appendingPathComponent("state_5.sqlite")
        ]
        self.stateDbURL = stateDbCandidateURLs[0]
    }
}

public enum CodexHistoryRootResolver {
    public static func resolveRootURL(customPath: String? = nil) -> URL {
        let fileManager = FileManager.default

        // 1. 自定义设置路径
        if let custom = customPath ?? UsageFeatureFlags.shared.customCodexHomePath,
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }

        // 2. CODEX_HOME 环境变量
        if let envPath = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (envPath as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }

        // 3. 默认 ~/.codex
        let defaultHome = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return defaultHome
    }

    public static func resolvePaths(customPath: String? = nil) -> CodexHistoryPaths {
        let root = resolveRootURL(customPath: customPath)
        return CodexHistoryPaths(rootURL: root)
    }
}

// MARK: - 文件源物理身份标识 (处理文件归档或重命名移动)
public struct RolloutSourceIdentity: Hashable, Sendable, Codable {
    public let device: UInt64
    public let inode: UInt64
    public let birthtimeNs: Int64?

    public init(device: UInt64, inode: UInt64, birthtimeNs: Int64?) {
        self.device = device
        self.inode = inode
        self.birthtimeNs = birthtimeNs
    }

    public var stableKey: String {
        if let birth = birthtimeNs {
            return "\(device):\(inode):\(birth)"
        }
        return "\(device):\(inode)"
    }
}
