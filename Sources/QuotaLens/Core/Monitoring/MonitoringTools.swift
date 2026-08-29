import Foundation

public struct MonitoringToolID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }

    public static let codex = MonitoringToolID(rawValue: "codex")
    public static let claude = MonitoringToolID(rawValue: "claude")
}

public enum ToolCapability: String, Codable, Hashable, Sendable {
    case quota
    case usage
    case history
    case sessions
    case resetCards
    case overlay
    case settings
}

public enum MonitoringToolAccent: String, Codable, Sendable {
    case cyan
    case amber
}

public struct MonitoringToolDescriptor: Identifiable, Sendable {
    public let id: MonitoringToolID
    public let displayName: String
    public let systemImage: String
    public let accent: MonitoringToolAccent
    public let usageProvider: UsageProvider
    public let capabilities: Set<ToolCapability>
    public let bundleIdentifiers: Set<String>

    public init(
        id: MonitoringToolID,
        displayName: String,
        systemImage: String,
        accent: MonitoringToolAccent,
        usageProvider: UsageProvider,
        capabilities: Set<ToolCapability>,
        bundleIdentifiers: Set<String>
    ) {
        self.id = id
        self.displayName = displayName
        self.systemImage = systemImage
        self.accent = accent
        self.usageProvider = usageProvider
        self.capabilities = capabilities
        self.bundleIdentifiers = bundleIdentifiers
    }
}

public struct ToolRegistry: Sendable {
    public static let shared = ToolRegistry()

    public let descriptors: [MonitoringToolDescriptor]

    public init() {
        self.descriptors = Self.builtInDescriptors
    }

    public init(descriptors: [MonitoringToolDescriptor]) {
        self.descriptors = descriptors
    }

    public func descriptor(for id: MonitoringToolID) -> MonitoringToolDescriptor? {
        descriptors.first { $0.id == id }
    }

    public func tool(forBundleIdentifier bundleIdentifier: String?) -> MonitoringToolID? {
        guard let bundleIdentifier else { return nil }
        return descriptors.first { $0.bundleIdentifiers.contains(bundleIdentifier) }?.id
    }

    private static let builtInDescriptors: [MonitoringToolDescriptor] = [
        MonitoringToolDescriptor(
            id: .codex,
            displayName: "Codex",
            systemImage: "terminal.fill",
            accent: .cyan,
            usageProvider: .codex,
            capabilities: [.quota, .usage, .history, .sessions, .resetCards, .overlay, .settings],
            bundleIdentifiers: ["com.openai.chat", "com.openai.codex"]
        ),
        MonitoringToolDescriptor(
            id: .claude,
            displayName: "Claude",
            systemImage: "sparkles",
            accent: .amber,
            usageProvider: .claude,
            capabilities: [.quota, .usage, .history, .sessions, .overlay, .settings],
            bundleIdentifiers: ["com.anthropic.claudefordesktop", "com.anthropic.Claude"]
        )
    ]
}

@MainActor
public final class EnabledToolsStore: ObservableObject {
    public static let defaultsKey = "QuotaLens.Monitoring.EnabledTools.v1"

    @Published public private(set) var enabledToolIDs: Set<MonitoringToolID>

    public init(defaults: UserDefaults = .standard) {
        if let stored = defaults.stringArray(forKey: Self.defaultsKey) {
            enabledToolIDs = Set(stored.map { MonitoringToolID(rawValue: $0) })
        } else {
            var migrated: Set<MonitoringToolID> = [.codex]
            if defaults.bool(forKey: ClaudeUsageSettings.enabledDefaultsKey) {
                migrated.insert(.claude)
            }
            enabledToolIDs = migrated
            persist(to: defaults)
        }
    }

    public var enabledDescriptors: [MonitoringToolDescriptor] {
        ToolRegistry.shared.descriptors.filter { enabledToolIDs.contains($0.id) }
    }

    public func isEnabled(_ id: MonitoringToolID) -> Bool {
        enabledToolIDs.contains(id)
    }

    public func setEnabled(_ enabled: Bool, for id: MonitoringToolID, defaults: UserDefaults = .standard) {
        guard ToolRegistry.shared.descriptor(for: id) != nil else { return }
        if enabled {
            enabledToolIDs.insert(id)
        } else {
            enabledToolIDs.remove(id)
        }
        persist(to: defaults)
    }

    public func resetToDefaults(defaults: UserDefaults = .standard) {
        enabledToolIDs = [.codex]
        persist(to: defaults)
    }

    private func persist(to defaults: UserDefaults) {
        defaults.set(enabledToolIDs.map(\.rawValue).sorted(), forKey: Self.defaultsKey)
    }
}

public enum AppContext: Hashable, Sendable {
    case overview
    case tool(MonitoringToolID)

    public var storageValue: String {
        switch self {
        case .overview:
            return "overview"
        case .tool(let id):
            return "tool:\(id.rawValue)"
        }
    }

    public init?(storageValue: String) {
        if storageValue == "overview" {
            self = .overview
            return
        }
        let prefix = "tool:"
        guard storageValue.hasPrefix(prefix) else { return nil }
        self = .tool(MonitoringToolID(rawValue: String(storageValue.dropFirst(prefix.count))))
    }
}
