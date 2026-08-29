import AppKit
import Combine
import Darwin
import Foundation

@MainActor
public final class FrontmostToolTracker: ObservableObject {
    private static let lastActiveDefaultsKey = "QuotaLens.Monitoring.LastActiveTool"
    private static let claudeHostBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders"
    ]
    private static let transientBundleIdentifiers: Set<String> = [
        "com.apple.SystemUIServer",
        "com.apple.dock",
        "com.apple.loginwindow"
    ]

    @Published public private(set) var foregroundTool: MonitoringToolID?
    @Published public private(set) var lastActiveTool: MonitoringToolID?
    @Published public private(set) var foregroundApplicationPID: pid_t?
    @Published public private(set) var foregroundBundleIdentifier: String?

    private let enabledTools: EnabledToolsStore
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    private var enabledToolsCancellable: AnyCancellable?

    public init(enabledTools: EnabledToolsStore, defaults: UserDefaults = .standard) {
        self.enabledTools = enabledTools
        if let rawValue = defaults.string(forKey: Self.lastActiveDefaultsKey) {
            let id = MonitoringToolID(rawValue: rawValue)
            self.lastActiveTool = enabledTools.isEnabled(id) ? id : nil
        }
        enabledToolsCancellable = enabledTools.$enabledToolIDs
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.removeDisabledStateAndRefresh()
                }
            }
    }

    deinit {
        pollTask?.cancel()
    }

    public func start() {
        guard workspaceObservers.isEmpty else {
            refresh()
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
        refresh()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    public func refresh() {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            foregroundTool = nil
            foregroundApplicationPID = nil
            foregroundBundleIdentifier = nil
            return
        }
        let bundleIdentifier = application.bundleIdentifier
        if Self.transientBundleIdentifiers.contains(bundleIdentifier ?? "") {
            return
        }

        foregroundApplicationPID = application.processIdentifier
        foregroundBundleIdentifier = bundleIdentifier
        if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            foregroundTool = nil
            return
        }

        var detected = ToolRegistry.shared.tool(forBundleIdentifier: bundleIdentifier)
        if detected == nil,
           application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "claude" {
            detected = .claude
        }
        if detected == nil,
           Self.claudeHostBundleIdentifiers.contains(bundleIdentifier ?? ""),
           hasClaudeDescendant(of: application) {
            detected = .claude
        }

        guard let detected, enabledTools.isEnabled(detected) else {
            foregroundTool = nil
            return
        }
        foregroundTool = detected
        if lastActiveTool != detected {
            lastActiveTool = detected
            UserDefaults.standard.set(detected.rawValue, forKey: Self.lastActiveDefaultsKey)
        }
    }

    private func removeDisabledStateAndRefresh() {
        if let foregroundTool, !enabledTools.isEnabled(foregroundTool) {
            self.foregroundTool = nil
        }
        if let lastActiveTool, !enabledTools.isEnabled(lastActiveTool) {
            self.lastActiveTool = nil
            UserDefaults.standard.removeObject(forKey: Self.lastActiveDefaultsKey)
        }
        refresh()
    }

    private func hasClaudeDescendant(of application: NSRunningApplication) -> Bool {
        let processes = ProcessTreeSnapshot.capture()
        let hostPID = application.processIdentifier
        let hostBundlePath = application.bundleURL?.path
        let parentByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0.parentPID) })
        let pathByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0.executablePath) })

        for process in processes where process.isClaudeExecutable {
            var cursor = process.parentPID
            var visited = Set<pid_t>()
            while cursor > 1, visited.insert(cursor).inserted {
                if cursor == hostPID {
                    return true
                }
                if let hostBundlePath,
                   let path = pathByPID[cursor],
                   path.hasPrefix(hostBundlePath + "/") {
                    return true
                }
                guard let parent = parentByPID[cursor] else { break }
                cursor = parent
            }
        }
        return false
    }
}

private struct ProcessTreeEntry {
    let pid: pid_t
    let parentPID: pid_t
    let name: String
    let executablePath: String

    var isClaudeExecutable: Bool {
        let normalized = name.lowercased()
        return normalized == "claude" || normalized.hasPrefix("claude-")
    }
}

private enum ProcessTreeSnapshot {
    static func capture() -> [ProcessTreeEntry] {
        let estimatedCount = max(0, Int(proc_listallpids(nil, 0)))
        guard estimatedCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: estimatedCount + 64)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let actualCount = pids.withUnsafeMutableBytes { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, byteCount)
        }
        guard actualCount > 0 else { return [] }

        return pids.prefix(Int(actualCount)).compactMap { pid in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, infoSize)
            }
            guard result == infoSize else { return nil }

            var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let nameLength = nameBuffer.withUnsafeMutableBytes { buffer in
                proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            let name = nameLength > 0 ? decodeCString(nameBuffer) : ""

            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let pathLength = pathBuffer.withUnsafeMutableBytes { buffer in
                proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            let path = pathLength > 0 ? decodeCString(pathBuffer) : ""
            return ProcessTreeEntry(
                pid: pid,
                parentPID: pid_t(info.pbi_ppid),
                name: name,
                executablePath: path
            )
        }
    }

    private static func decodeCString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
