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

public struct RolloutScanDiagnostic: Hashable, Sendable {
    public let fileURL: URL
    public let relativePath: String
    public let bucket: SessionBucket
    public let code: String
    public let message: String

    public init(
        fileURL: URL,
        relativePath: String,
        bucket: SessionBucket,
        code: String,
        message: String
    ) {
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.bucket = bucket
        self.code = code
        self.message = message
    }
}

public enum RootScanStatus: Hashable, Sendable {
    case success
    case notFound
    case disabled
    case inaccessible
    case failed(String)

    public var allowsTombstone: Bool {
        if case .success = self { return true }
        return false
    }
}

public struct ScanOutcome: Sendable {
    public let active: RootScanStatus
    public let archived: RootScanStatus
    public let sources: [RolloutDiscoveredSource]
    public let diagnostics: [RolloutScanDiagnostic]

    public init(
        active: RootScanStatus,
        archived: RootScanStatus,
        sources: [RolloutDiscoveredSource],
        diagnostics: [RolloutScanDiagnostic] = []
    ) {
        self.active = active
        self.archived = archived
        self.sources = sources
        self.diagnostics = diagnostics
    }

    public func status(for bucket: SessionBucket) -> RootScanStatus {
        switch bucket {
        case .active: return active
        case .archived: return archived
        }
    }
}

public enum CodexRolloutScanner {
    public typealias EnumeratorFactory = (
        _ directoryURL: URL,
        _ keys: [URLResourceKey],
        _ options: FileManager.DirectoryEnumerationOptions,
        _ errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator?

    struct RolloutFileMetadata: Sendable {
        let identity: RolloutSourceIdentity
        let fileSize: Int64
        let mtimeMs: Int64
    }

    typealias FileProbe = (_ fileURL: URL, _ hasCanonicalName: Bool) throws -> RolloutFileMetadata?

    public static func scan(
        paths: CodexHistoryPaths,
        scanArchived: Bool = true,
        enumeratorFactory: EnumeratorFactory? = nil
    ) -> ScanOutcome {
        scan(
            paths: paths,
            scanArchived: scanArchived,
            enumeratorFactory: enumeratorFactory,
            fileProbe: probeRolloutFile
        )
    }

    /// 确定性故障测试使用的内部注入点；单文件探测错误会让对应根目录扫描不完整，从而阻止该根目录 tombstone 旧源。
    static func scan(
        paths: CodexHistoryPaths,
        scanArchived: Bool = true,
        enumeratorFactory: EnumeratorFactory? = nil,
        fileProbe: @escaping FileProbe
    ) -> ScanOutcome {
        var results: [RolloutDiscoveredSource] = []
        var diagnostics: [RolloutScanDiagnostic] = []
        let fileManager = FileManager.default

        let active = scanRoot(
            paths.sessionsURL,
            baseRootURL: paths.rootURL,
            bucket: .active,
            fileManager: fileManager,
            enumeratorFactory: enumeratorFactory,
            fileProbe: fileProbe
        )
        results.append(contentsOf: active.sources)
        diagnostics.append(contentsOf: active.diagnostics)

        let archived: (status: RootScanStatus, sources: [RolloutDiscoveredSource], diagnostics: [RolloutScanDiagnostic])
        if scanArchived {
            archived = scanRoot(
                paths.archivedSessionsURL,
                baseRootURL: paths.rootURL,
                bucket: .archived,
                fileManager: fileManager,
                enumeratorFactory: enumeratorFactory,
                fileProbe: fileProbe
            )
            results.append(contentsOf: archived.sources)
            diagnostics.append(contentsOf: archived.diagnostics)
        } else {
            archived = (.disabled, [], [])
        }

        // 稳定排序：按 mtime 倒序，同时间按相对路径排序
        let sorted = results.sorted {
            if $0.mtimeMs != $1.mtimeMs {
                return $0.mtimeMs > $1.mtimeMs
            }
            return $0.relativePath < $1.relativePath
        }
        return ScanOutcome(
            active: active.status,
            archived: archived.status,
            sources: sorted,
            diagnostics: diagnostics.sorted { lhs, rhs in
                if lhs.bucket != rhs.bucket {
                    return lhs.bucket.rawValue < rhs.bucket.rawValue
                }
                return lhs.relativePath < rhs.relativePath
            }
        )
    }

    public static func scanSources(paths: CodexHistoryPaths, scanArchived: Bool = true) -> [RolloutDiscoveredSource] {
        scan(paths: paths, scanArchived: scanArchived).sources
    }

    private static func scanRoot(
        _ directoryURL: URL,
        baseRootURL: URL,
        bucket: SessionBucket,
        fileManager: FileManager,
        enumeratorFactory: EnumeratorFactory?,
        fileProbe: @escaping FileProbe
    ) -> (status: RootScanStatus, sources: [RolloutDiscoveredSource], diagnostics: [RolloutScanDiagnostic]) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            return (.notFound, [], [])
        }
        guard isDirectory.boolValue else {
            return (.failed("Not a directory"), [], [])
        }
        guard fileManager.isReadableFile(atPath: directoryURL.path) else {
            return (.inaccessible, [], [])
        }

        var traversalError: Error?
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        let errorHandler: (URL, Error) -> Bool = { _, error in
            traversalError = error
            return false
        }
        let factory = enumeratorFactory ?? { directoryURL, keys, options, errorHandler in
            fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: errorHandler
            )
        }
        guard let enumerator = factory(
            directoryURL,
            keys,
            options,
            errorHandler
        ) else {
            return (.failed("Enumerator unavailable"), [], [])
        }

        let directoryScan = scanDirectory(
            enumerator: enumerator,
            directoryURL: directoryURL,
            baseRootURL: baseRootURL,
            bucket: bucket,
            fileProbe: fileProbe
        )
        if let traversalError {
            return (.failed(traversalError.localizedDescription), directoryScan.sources, directoryScan.diagnostics)
        }
        if let fileFailure = directoryScan.failureDescription {
            return (.failed(fileFailure), directoryScan.sources, directoryScan.diagnostics)
        }
        return (.success, directoryScan.sources, directoryScan.diagnostics)
    }

    private static func scanDirectory(
        enumerator: FileManager.DirectoryEnumerator,
        directoryURL: URL,
        baseRootURL: URL,
        bucket: SessionBucket,
        fileProbe: @escaping FileProbe
    ) -> (sources: [RolloutDiscoveredSource], diagnostics: [RolloutScanDiagnostic], failureDescription: String?) {
        var list: [RolloutDiscoveredSource] = []
        var diagnostics: [RolloutScanDiagnostic] = []
        var failureDescription: String?
        let baseRootPath = baseRootURL.path

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let fileName = url.lastPathComponent
            let relPath = url.path.hasPrefix(baseRootPath)
                ? String(url.path.dropFirst(baseRootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : url.lastPathComponent
            let hasCanonicalName = isCanonicalRolloutFileName(fileName)
            let metadata: RolloutFileMetadata
            do {
                guard let probed = try fileProbe(url, hasCanonicalName) else {
                    if !hasCanonicalName {
                        diagnostics.append(
                            RolloutScanDiagnostic(
                                fileURL: url,
                                relativePath: relPath,
                                bucket: bucket,
                                code: "non_rollout_jsonl_probe_miss",
                                message: "非标准 JSONL 在 1 MiB / 200 个非空行探测窗口内未发现 Codex rollout 结构，已跳过。"
                            )
                        )
                    }
                    continue
                }
                metadata = probed
            } catch {
                if failureDescription == nil {
                    failureDescription = "\(url.path): \(error.localizedDescription)"
                }
                continue
            }

            let sessionId = extractSessionId(from: fileName, relativePath: relPath)

            list.append(
                RolloutDiscoveredSource(
                    fileURL: url,
                    relativePath: relPath,
                    bucket: bucket,
                    sessionId: sessionId,
                    identity: metadata.identity,
                    fileSize: metadata.fileSize,
                    mtimeMs: metadata.mtimeMs
                )
            )
        }

        return (list, diagnostics, failureDescription)
    }

    private static func isCanonicalRolloutFileName(_ fileName: String) -> Bool {
        guard fileName.hasSuffix(".jsonl") else { return false }
        return fileName.range(
            of: #"^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.jsonl$"#,
            options: .regularExpression
        ) != nil
    }

    private static func probeRolloutFile(
        fileURL: URL,
        hasCanonicalName: Bool
    ) throws -> RolloutFileMetadata? {
        if !hasCanonicalName {
            guard try containsRolloutStructure(fileURL: fileURL) else { return nil }
        }

        var statBuf = stat()
        let status = stat((fileURL.path as NSString).fileSystemRepresentation, &statBuf)
        guard status == 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSFilePathErrorKey: fileURL.path]
            )
        }
        guard (statBuf.st_mode & S_IFMT) == S_IFREG else { return nil }

        let birthtimeNs = Int64(statBuf.st_birthtimespec.tv_sec) * 1_000_000_000
            + Int64(statBuf.st_birthtimespec.tv_nsec)
        return RolloutFileMetadata(
            identity: RolloutSourceIdentity(
                device: UInt64(statBuf.st_dev),
                inode: UInt64(statBuf.st_ino),
                birthtimeNs: birthtimeNs > 0 ? birthtimeNs : nil
            ),
            fileSize: Int64(statBuf.st_size),
            mtimeMs: Int64(statBuf.st_mtimespec.tv_sec) * 1_000
                + Int64(statBuf.st_mtimespec.tv_nsec / 1_000_000)
        )
    }

    private static func containsRolloutStructure(fileURL: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return false }
        var nonEmptyLines = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            nonEmptyLines += 1
            guard nonEmptyLines <= 200 else { break }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let outerType = (json["type"] as? String ?? json["event"] as? String ?? "").lowercased()
            let payload = (json["payload"] as? [String: Any]) ?? json
            let payloadType = (payload["type"] as? String ?? "").lowercased()
            if outerType == "session_meta" || payload["session_id"] != nil || payload["id"] != nil && payload["cwd"] != nil {
                return true
            }
            if outerType == "event_msg" && ["token_count", "turn_context", "task_started", "user_message"].contains(payloadType) {
                return true
            }
            if payload["last_token_usage"] != nil
                || payload["total_token_usage"] != nil
                || (payload["info"] as? [String: Any])?["last_token_usage"] != nil
                || (payload["info"] as? [String: Any])?["total_token_usage"] != nil {
                return true
            }
        }
        return false
    }

    public static func extractSessionId(from fileName: String, relativePath: String) -> String {
        let nameWithoutExtension = fileName.hasSuffix(".jsonl")
            ? String(fileName.dropLast(".jsonl".count))
            : fileName

        // 当前 Codex rollout 文件名通常是 rollout-<timestamp>-<session-uuid>.jsonl。
        // 元数据只保存 UUID，因此优先使用末尾 UUID 形态片段，而不是完整文件名 stem。
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
