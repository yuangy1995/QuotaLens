import Foundation

public enum AntigravityQuotaWindow: String, Codable, Sendable {
    case fiveHour
    case weekly
    case other

    public init(bucketID: String?, window: String?) {
        let value = "\(bucketID ?? "") \(window ?? "")".lowercased()
        if value.contains("5h") || value.contains("five") {
            self = .fiveHour
        } else if value.contains("weekly") || value.contains("week") {
            self = .weekly
        } else {
            self = .other
        }
    }

    public var localizedTitle: String {
        switch self {
        case .fiveHour: return L10n.text("5 小时", "5 Hours")
        case .weekly: return L10n.text("7 天", "7 Days")
        case .other: return L10n.text("其他窗口", "Other Window")
        }
    }

    public var displayOrder: Int {
        switch self {
        case .fiveHour: return 0
        case .weekly: return 1
        case .other: return 2
        }
    }
}

public enum AntigravityQuotaStatus: Equatable, Sendable {
    case disabled
    case loading
    case available
    case missingCredentials
    case signInRequired
    case needsInitialization
    case limited(until: Date?)
    case unavailable
}

public struct AntigravityQuotaSnapshot: Equatable, Sendable, Codable {
    public struct Bucket: Identifiable, Equatable, Sendable, Codable {
        public let id: String
        public let title: String
        public let window: AntigravityQuotaWindow
        public let remainingPercent: Double
        public let resetAt: Date?

        public init(
            id: String,
            title: String,
            window: AntigravityQuotaWindow,
            remainingPercent: Double,
            resetAt: Date?
        ) {
            self.id = id
            self.title = title
            self.window = window
            self.remainingPercent = min(max(remainingPercent, 0), 100)
            self.resetAt = resetAt
        }
    }

    public struct Group: Identifiable, Equatable, Sendable, Codable {
        public let id: String
        public let title: String
        public let buckets: [Bucket]

        public init(id: String, title: String, buckets: [Bucket]) {
            self.id = id
            self.title = title
            self.buckets = buckets
        }
    }

    public struct DisplayBucket: Identifiable, Equatable, Sendable {
        public let groupTitle: String
        public let bucket: Bucket
        let groupOrder: Int

        public var id: String { "\(groupTitle):\(bucket.id)" }

        public init(groupTitle: String, bucket: Bucket, groupOrder: Int = 0) {
            self.groupTitle = groupTitle
            self.bucket = bucket
            self.groupOrder = groupOrder
        }
    }

    struct CompactFiveHourBucket: Identifiable, Equatable, Sendable {
        let groupTitle: String
        let displayTitle: String
        let shortTitle: String
        let bucket: Bucket
        let groupOrder: Int

        var id: String { "\(groupTitle):\(bucket.id)" }

        init(
            groupTitle: String,
            displayTitle: String,
            shortTitle: String,
            bucket: Bucket,
            groupOrder: Int
        ) {
            self.groupTitle = groupTitle
            self.displayTitle = displayTitle
            self.shortTitle = shortTitle
            self.bucket = bucket
            self.groupOrder = groupOrder
        }
    }

    public struct Model: Identifiable, Equatable, Sendable, Codable {
        public let id: String
        public let displayName: String?
        public let remainingPercent: Double
        public let resetAt: Date?

        public init(id: String, displayName: String?, remainingPercent: Double, resetAt: Date?) {
            self.id = id
            self.displayName = displayName
            self.remainingPercent = min(max(remainingPercent, 0), 100)
            self.resetAt = resetAt
        }
    }

    public let sourceProfile: String
    public let accountKey: String
    public let accountDisplayName: String?
    public let planName: String?
    public let capturedAt: Date
    public let groups: [Group]
    public let models: [Model]

    public init(
        sourceProfile: String,
        accountKey: String,
        accountDisplayName: String?,
        planName: String?,
        capturedAt: Date,
        groups: [Group],
        models: [Model]
    ) {
        self.sourceProfile = sourceProfile
        self.accountKey = accountKey
        self.accountDisplayName = accountDisplayName
        self.planName = planName
        self.capturedAt = capturedAt
        self.groups = groups
        self.models = models
    }

    public var buckets: [Bucket] {
        groups.flatMap(\.buckets)
    }

    public var orderedDisplayBuckets: [DisplayBucket] {
        var result: [DisplayBucket] = []
        for (groupOrder, group) in groups.enumerated() {
            result.append(contentsOf: group.buckets.map {
                DisplayBucket(groupTitle: group.title, bucket: $0, groupOrder: groupOrder)
            })
        }
        return result.sorted {
                if $0.bucket.window.displayOrder != $1.bucket.window.displayOrder {
                    return $0.bucket.window.displayOrder < $1.bucket.window.displayOrder
                }
                if $0.groupOrder != $1.groupOrder {
                    return $0.groupOrder < $1.groupOrder
                }
                return $0.bucket.id < $1.bucket.id
            }
    }

    var orderedCompactFiveHourBuckets: [CompactFiveHourBucket] {
        groups.enumerated().flatMap { groupOrder, group in
            group.buckets
                .filter { $0.window == .fiveHour }
                .map {
                    CompactFiveHourBucket(
                        groupTitle: group.title,
                        displayTitle: Self.groupDisplayTitle(for: group.title),
                        shortTitle: Self.compactGroupTitle(for: group.title),
                        bucket: $0,
                        groupOrder: Self.compactGroupOrder(for: group.title, fallback: groupOrder)
                    )
                }
        }.sorted {
            if $0.groupOrder != $1.groupOrder { return $0.groupOrder < $1.groupOrder }
            return $0.bucket.id < $1.bucket.id
        }
    }

    static func compactGroupTitle(for groupTitle: String) -> String {
        let normalized = groupTitle.lowercased()
        if normalized.contains("gemini") { return "G" }
        if normalized.contains("claude") || normalized.contains("gpt") { return "C/GPT" }
        return groupTitle
    }

    static func groupDisplayTitle(for groupTitle: String) -> String {
        let normalized = groupTitle.lowercased()
        if normalized.contains("gemini") { return "Gemini" }
        if normalized.contains("claude") || normalized.contains("gpt") { return "Claude/GPT" }
        return groupTitle
    }

    private static func compactGroupOrder(for groupTitle: String, fallback: Int) -> Int {
        let normalized = groupTitle.lowercased()
        if normalized.contains("gemini") { return 0 }
        if normalized.contains("claude") || normalized.contains("gpt") { return 1 }
        return fallback + 2
    }

    public var lowestRemainingPercent: Double? {
        let values = buckets.map(\.remainingPercent) + models.map(\.remainingPercent)
        return values.min()
    }

    public var hasQuota: Bool {
        !groups.isEmpty || !models.isEmpty
    }
}

public struct AntigravityActivitySnapshot: Equatable, Sendable {
    public struct Day: Identifiable, Equatable, Sendable {
        public let date: Date
        public let taskCount: Int
        public let stepCount: Int64

        public var id: Date { date }
    }

    public let capturedAt: Date
    public let taskCount7Days: Int
    public let taskCount30Days: Int
    public let activeDays30Days: Int
    public let stepCount30Days: Int64
    public let latestActivityAt: Date?
    public let daily: [Day]
    public let projectCounts: [String: Int]

    public init(
        capturedAt: Date,
        taskCount7Days: Int,
        taskCount30Days: Int,
        activeDays30Days: Int,
        stepCount30Days: Int64,
        latestActivityAt: Date?,
        daily: [Day],
        projectCounts: [String: Int]
    ) {
        self.capturedAt = capturedAt
        self.taskCount7Days = taskCount7Days
        self.taskCount30Days = taskCount30Days
        self.activeDays30Days = activeDays30Days
        self.stepCount30Days = stepCount30Days
        self.latestActivityAt = latestActivityAt
        self.daily = daily
        self.projectCounts = projectCounts
    }
}

public enum AntigravityStateProfile: String, Codable, Sendable {
    case ide
    case legacy

    public var displayName: String {
        self == .ide ? "Antigravity IDE" : "Antigravity"
    }
}

public struct AntigravityStateSource: Equatable, Sendable {
    public let profile: AntigravityStateProfile
    public let databaseURL: URL

    public init(profile: AntigravityStateProfile, databaseURL: URL) {
        self.profile = profile
        self.databaseURL = databaseURL
    }
}
