// QuotaLens Codex 会话与归档 JSONL 文件扫描器
// 递归遍历 sessions/ 与 archived_sessions/，提取低开销物理属性，避免无谓的文件全量读取

import Foundation

public struct RolloutDiscoveredSource: Hashable, Sendable {
    public let fileURL: URL
    public let relativePath: String
    public let bucket: SessionBucket
    public let sessionId: String
    public let identity: RolloutSourceIdentity
    public let fileSize: Int64
    public let mtimeMs: Int64

    public init(
        fileURL: URL,
        relativePath: String,
        bucket: SessionBucket,
        sessionId: String,
        identity: RolloutSourceIdentity,
        fileSize: Int64,
        mtimeMs: Int64
    ) {
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.bucket = bucket
        self.sessionId = sessionId
        self.identity = identity
        self.fileSize = fileSize
        self.mtimeMs = mtimeMs
    }
}

public enum CodexRolloutScanner {
    public static func scan(paths: CodexHistoryPaths, scanArchived: Bool = true) -> [RolloutDiscoveredSource] {
        var results: [RolloutDiscoveredSource] = []
        let fileManager = FileManager.default

        // 1. 扫描活动会话目录
        if fileManager.fileExists(atPath: paths.sessionsURL.path) {
            results.append(contentsOf: scanDirectory(paths.sessionsURL, baseRootURL: paths.rootURL, bucket: .active))
        }

        // 2. 扫描归档会话目录
        if scanArchived && fileManager.fileExists(atPath: paths.archivedSessionsURL.path) {
            results.append(contentsOf: scanDirectory(paths.archivedSessionsURL, baseRootURL: paths.rootURL, bucket: .archived))
        }

        // 稳定排序：按 mtime 倒序，同时间按相对路径排序
        return results.sorted {
            if $0.mtimeMs != $1.mtimeMs {
                return $0.mtimeMs > $1.mtimeMs
            }
            return $0.relativePath < $1.relativePath
        }
    }

    private static func scanDirectory(_ directoryURL: URL, baseRootURL: URL, bucket: SessionBucket) -> [RolloutDiscoveredSource] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var list: [RolloutDiscoveredSource] = []
        let baseRootPath = baseRootURL.path

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let fileName = url.lastPathComponent
            guard fileName.hasPrefix("rollout") || fileName.contains("session") || fileName.contains("-") else { continue }

            var statBuf = stat()
            let status = stat((url.path as NSString).fileSystemRepresentation, &statBuf)
            guard status == 0 else { continue }

            let isRegular = (statBuf.st_mode & S_IFMT) == S_IFREG
            guard isRegular else { continue }

            let fileSize = Int64(statBuf.st_size)
            let mtimeMs = Int64(statBuf.st_mtimespec.tv_sec) * 1000 + Int64(statBuf.st_mtimespec.tv_nsec / 1_000_000)
            let birthtimeNs = Int64(statBuf.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(statBuf.st_birthtimespec.tv_nsec)

            let identity = RolloutSourceIdentity(
                device: UInt64(statBuf.st_dev),
                inode: UInt64(statBuf.st_ino),
                birthtimeNs: birthtimeNs > 0 ? birthtimeNs : nil
            )

            let relPath = url.path.hasPrefix(baseRootPath)
                ? String(url.path.dropFirst(baseRootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : url.lastPathComponent

            let sessionId = extractSessionId(from: fileName, relativePath: relPath)

            list.append(
                RolloutDiscoveredSource(
                    fileURL: url,
                    relativePath: relPath,
                    bucket: bucket,
                    sessionId: sessionId,
                    identity: identity,
                    fileSize: fileSize,
                    mtimeMs: mtimeMs
                )
            )
        }

        return list
    }

    public static func extractSessionId(from fileName: String, relativePath: String) -> String {
        let nameWithoutExtension = fileName.hasSuffix(".jsonl")
            ? String(fileName.dropLast(".jsonl".count))
            : fileName

        // Current Codex rollout names are usually
        // rollout-<timestamp>-<session-uuid>.jsonl. The metadata stores only
        // the UUID, so prefer the last UUID-looking segment over the full stem.
        if let uuidRange = nameWithoutExtension.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
            options: .regularExpression
        ) {
            return String(nameWithoutExtension[uuidRange]).lowercased()
        }

        if fileName.hasPrefix("rollout-") && fileName.hasSuffix(".jsonl") {
            let core = nameWithoutExtension.dropFirst("rollout-".count)
            return String(core)
        }
        return nameWithoutExtension
    }
}
