import Foundation

public struct LocalScanIssue: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case read, format, incomplete }
    public let source: URL?
    public let kind: Kind
    public let reason: String
    public var id: String { kind.rawValue + ":" + (source?.standardizedFileURL.path ?? "scan") }
}

public struct LocalScanDiagnostics: Equatable, Sendable {
    public let checkedAt: Date?
    public let issues: [LocalScanIssue]
    public var sourcesFound = true
    public static let unchecked = Self(checkedAt: nil, issues: [])
    public var isPartial: Bool { !issues.isEmpty }
    public func count(_ kind: LocalScanIssue.Kind) -> Int? {
        guard checkedAt != nil, sourcesFound, !issues.contains(where: { $0.source == nil }) else { return nil }
        return Set(issues.filter { $0.kind == kind }.compactMap { $0.source?.standardizedFileURL.path }).count
    }
}

enum IndexedSourcePresence: Equatable {
    case present, missing, unknown
    static func inspect(_ paths: [String], attributes: (String) throws -> [FileAttributeKey: Any] = FileManager.default.attributesOfItem) -> Self {
        let paths = Set(paths.filter { !$0.isEmpty })
        guard !paths.isEmpty else { return .unknown }
        var unknown = false
        for path in paths {
            do { _ = try attributes(path); return .present }
            catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { continue }
            catch { unknown = true }
        }
        return unknown ? .unknown : .missing
    }
}
