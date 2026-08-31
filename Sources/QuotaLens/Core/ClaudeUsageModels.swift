import Foundation

public struct ClaudeUsageSnapshot: Equatable, Sendable, Codable {
    public struct Window: Equatable, Sendable, Identifiable, Codable {
        public let id: String
        public let title: String
        public let usedPercent: Double
        public let resetAt: Date
        public let windowDuration: TimeInterval

        public init(
            id: String,
            title: String,
            usedPercent: Double,
            resetAt: Date,
            windowDuration: TimeInterval
        ) {
            self.id = id
            self.title = title
            self.usedPercent = min(max(usedPercent, 0), 100)
            self.resetAt = resetAt
            self.windowDuration = windowDuration
        }

        public var remainingPercent: Double { max(0, 100 - usedPercent) }
        public var isStale: Bool { resetAt <= Date() }
        public var localizedTitle: String {
            switch id {
            case "claude": return L10n.text("5 小时", "5 Hours")
            case "claude-weekly": return L10n.text("7 天", "7 Days")
            default: return title
            }
        }
    }

    public let capturedAt: Date
    public let accountKey: String
    public let accountIdentityConfidence: AccountIdentityConfidence?
    public let accountAliases: Set<String>?
    public let tier: String?
    public let fiveHour: Window?
    public let staleFiveHour: Window?
    public let sevenDay: Window?
    public let scopedWeekly: [Window]

    public init(
        capturedAt: Date,
        accountKey: String,
        tier: String?,
        fiveHour: Window?,
        staleFiveHour: Window? = nil,
        sevenDay: Window?,
        scopedWeekly: [Window] = [],
        accountIdentityConfidence: AccountIdentityConfidence? = nil,
        accountAliases: Set<String>? = nil
    ) {
        self.capturedAt = capturedAt
        self.accountKey = accountKey
        self.accountIdentityConfidence = accountIdentityConfidence
        self.accountAliases = accountAliases
        self.tier = tier
        self.fiveHour = fiveHour
        self.staleFiveHour = staleFiveHour
        self.sevenDay = sevenDay
        var seen = Set<String>()
        self.scopedWeekly = scopedWeekly.filter { seen.insert($0.id).inserted }
    }

    public var fiveHourForDisplay: Window? { fiveHour ?? staleFiveHour }
    public var hasQuota: Bool {
        fiveHour != nil || staleFiveHour != nil || sevenDay != nil || !scopedWeekly.isEmpty
    }

    public func preservingStaleFiveHour(from previous: ClaudeUsageSnapshot?) -> ClaudeUsageSnapshot {
        guard fiveHour == nil,
              staleFiveHour == nil,
              previous?.accountKey == accountKey,
              sevenDay != nil || !scopedWeekly.isEmpty,
              let old = previous?.fiveHour ?? previous?.staleFiveHour,
              old.resetAt <= capturedAt else {
            return self
        }
        return ClaudeUsageSnapshot(
            capturedAt: capturedAt,
            accountKey: accountKey,
            tier: tier,
            fiveHour: nil,
            staleFiveHour: old,
            sevenDay: sevenDay,
            scopedWeekly: scopedWeekly,
            accountIdentityConfidence: accountIdentityConfidence,
            accountAliases: accountAliases
        )
    }
}

public enum ClaudeUsageStatus: Equatable, Sendable {
    case disabled
    case loading
    case available
    case missingCredentials
    case signInRequired
    case limited(until: Date?)
    case unavailable
}

public struct ClaudeUsageImportSummary: Sendable, Equatable {
    public let filesScanned: Int
    public let filesChanged: Int
    public let sessionsUpdated: Int
    public let eventsUpdated: Int
    public let errors: [String]

    public static let empty = ClaudeUsageImportSummary(
        filesScanned: 0,
        filesChanged: 0,
        sessionsUpdated: 0,
        eventsUpdated: 0,
        errors: []
    )
}

@MainActor
public final class ClaudeUsageSettings: ObservableObject, @unchecked Sendable {
    public static let shared = ClaudeUsageSettings()
    public static let enabledDefaultsKey = "QuotaLens.Claude.Enabled"

    @Published public var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    public func resetToDefaults() {
        isEnabled = false
    }
}
