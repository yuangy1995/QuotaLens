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

struct AntigravityQuotaFailurePresentation: Equatable {
    let status: AntigravityQuotaStatus
    let message: String

    static func make(
        error: Error,
        accountResolution: AccountResolutionState?,
        hasCachedQuota: Bool
    ) -> Self {
        if let error = error as? AntigravityCredentialError {
            return Self(
                status: error == .credentialsMissing ? .missingCredentials : .unavailable,
                message: error.errorDescription ?? genericUnavailableMessage
            )
        }
        guard let error = error as? AntigravityFetchError else {
            return resolvingFallback(accountResolution: accountResolution, hasCachedQuota: hasCachedQuota)
                ?? Self(status: .unavailable, message: genericUnavailableMessage)
        }
        switch error {
        case .missingCredentials:
            return Self(
                status: .missingCredentials,
                message: L10n.text("请先在 Antigravity 中登录。", "Sign in to Antigravity first.")
            )
        case .unauthorized:
            return Self(
                status: .signInRequired,
                message: L10n.text(
                    "Antigravity 登录已失效，请重新登录。",
                    "Your Antigravity sign-in has expired. Sign in again."
                )
            )
        case .forbidden:
            return Self(
                status: .unavailable,
                message: L10n.text(
                    "当前账号暂时无法读取 Antigravity 额度。",
                    "This account cannot read Antigravity quota right now."
                )
            )
        case .needsInitialization:
            return Self(
                status: .needsInitialization,
                message: L10n.text(
                    "请先在 Antigravity 中完成首次设置。",
                    "Finish the initial Antigravity setup first."
                )
            )
        case .rateLimited:
            return Self(
                status: .limited(until: nil),
                message: L10n.text(
                    "Antigravity 暂时延迟刷新，将自动重试。",
                    "Antigravity refresh is delayed and will retry automatically."
                )
            )
        case .malformedCredentials, .incompatibleResponse, .partialResponse:
            return Self(
                status: .unavailable,
                message: L10n.format(
                    "%@ quota could not be read completely. Check for a QuotaLens update.",
                    zhHans: "暂时无法完整读取 %@ 额度，请检查 QuotaLens 更新。",
                    "Antigravity"
                )
            )
        case .endpointUnavailable:
            return Self(
                status: .unavailable,
                message: L10n.text(
                    "Antigravity 的额度服务暂时不可用，请检查 QuotaLens 更新。",
                    "Antigravity quota service is unavailable. Check for a QuotaLens update."
                )
            )
        case .unavailable:
            return resolvingFallback(accountResolution: accountResolution, hasCachedQuota: hasCachedQuota)
                ?? Self(status: .unavailable, message: genericUnavailableMessage)
        case .noQuotaData:
            return Self(status: .unavailable, message: genericUnavailableMessage)
        }
    }

    private static func resolvingFallback(
        accountResolution: AccountResolutionState?,
        hasCachedQuota: Bool
    ) -> Self? {
        guard case .resolving = accountResolution, hasCachedQuota else { return nil }
        return Self(
            status: .available,
            message: L10n.text(
                "正在确认 Antigravity 账号，当前显示上次缓存。",
                "Confirming the Antigravity account. Showing the previous cache for now."
            )
        )
    }

    private static var genericUnavailableMessage: String {
        L10n.text(
            "暂时无法更新 Antigravity 额度。",
            "Antigravity quota could not be updated right now."
        )
    }
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

    public struct AggregatedModel: Identifiable, Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let remainingPercent: Double
        public let resetAt: Date?
        public let modelCount: Int

        public init(
            id: String,
            displayName: String,
            remainingPercent: Double,
            resetAt: Date?,
            modelCount: Int
        ) {
            self.id = id
            self.displayName = displayName
            self.remainingPercent = remainingPercent
            self.resetAt = resetAt
            self.modelCount = modelCount
        }
    }

    public let sourceProfile: String
    public let accountKey: String
    public let accountDisplayName: String?
    public let planName: String?
    public let capturedAt: Date
    public let groups: [Group]
    public let models: [Model]
    public let legacyAccountKey: String?

    public init(
        sourceProfile: String,
        accountKey: String,
        accountDisplayName: String?,
        planName: String?,
        capturedAt: Date,
        groups: [Group],
        models: [Model],
        legacyAccountKey: String? = nil
    ) {
        self.sourceProfile = sourceProfile
        self.accountKey = accountKey
        self.accountDisplayName = accountDisplayName
        self.planName = planName
        self.capturedAt = capturedAt
        self.groups = groups
        self.models = models
        self.legacyAccountKey = legacyAccountKey
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

    public var aggregatedModels: [AggregatedModel] {
        struct Aggregate {
            var displayName: String
            var remainingPercent: Double
            var resetAt: Date?
            var count: Int
        }

        var aggregates: [String: Aggregate] = [:]
        for model in models {
            let trimmed = model.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = trimmed?.isEmpty == false
                ? trimmed!
                : L10n.text("其他模型", "Other models")
            let key = displayName.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if var existing = aggregates[key] {
                existing.remainingPercent = min(existing.remainingPercent, model.remainingPercent)
                if let reset = model.resetAt {
                    existing.resetAt = existing.resetAt.map { min($0, reset) } ?? reset
                }
                existing.count += 1
                aggregates[key] = existing
            } else {
                aggregates[key] = Aggregate(
                    displayName: displayName,
                    remainingPercent: model.remainingPercent,
                    resetAt: model.resetAt,
                    count: 1
                )
            }
        }
        return aggregates.map { key, value in
            AggregatedModel(
                id: key,
                displayName: value.displayName,
                remainingPercent: value.remainingPercent,
                resetAt: value.resetAt,
                modelCount: value.count
            )
        }.sorted {
            if $0.remainingPercent != $1.remainingPercent {
                return $0.remainingPercent < $1.remainingPercent
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
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

    public struct PeriodMetrics: Equatable, Sendable {
        public let days: Int
        public let taskCount: Int
        public let activeDays: Int
        public let stepCount: Int64

        public init(days: Int, taskCount: Int, activeDays: Int, stepCount: Int64) {
            self.days = days
            self.taskCount = taskCount
            self.activeDays = activeDays
            self.stepCount = stepCount
        }

        public var averageStepsPerTask: Double {
            taskCount > 0 ? Double(stepCount) / Double(taskCount) : 0
        }

        public var tasksPerActiveDay: Double {
            activeDays > 0 ? Double(taskCount) / Double(activeDays) : 0
        }
    }

    public let capturedAt: Date
    public let taskCount7Days: Int
    public let taskCount30Days: Int
    public let activeDays30Days: Int
    public let stepCount30Days: Int64
    public let latestActivityAt: Date?
    public let daily: [Day]
    public let projectCounts: [String: Int]
    public let sevenDayMetrics: PeriodMetrics
    public let previousSevenDayMetrics: PeriodMetrics
    public let thirtyDayMetrics: PeriodMetrics
    public let previousThirtyDayMetrics: PeriodMetrics

    public init(
        capturedAt: Date,
        taskCount7Days: Int,
        taskCount30Days: Int,
        activeDays30Days: Int,
        stepCount30Days: Int64,
        latestActivityAt: Date?,
        daily: [Day],
        projectCounts: [String: Int],
        sevenDayMetrics: PeriodMetrics,
        previousSevenDayMetrics: PeriodMetrics,
        thirtyDayMetrics: PeriodMetrics,
        previousThirtyDayMetrics: PeriodMetrics
    ) {
        self.capturedAt = capturedAt
        self.taskCount7Days = taskCount7Days
        self.taskCount30Days = taskCount30Days
        self.activeDays30Days = activeDays30Days
        self.stepCount30Days = stepCount30Days
        self.latestActivityAt = latestActivityAt
        self.daily = daily
        self.projectCounts = projectCounts
        self.sevenDayMetrics = sevenDayMetrics
        self.previousSevenDayMetrics = previousSevenDayMetrics
        self.thirtyDayMetrics = thirtyDayMetrics
        self.previousThirtyDayMetrics = previousThirtyDayMetrics
    }

    public func metrics(days: Int) -> PeriodMetrics {
        days == 7 ? sevenDayMetrics : thirtyDayMetrics
    }

    public func previousMetrics(days: Int) -> PeriodMetrics {
        days == 7 ? previousSevenDayMetrics : previousThirtyDayMetrics
    }

    public func dailyPoints(days: Int) -> [Day] {
        Array(daily.suffix(days == 7 ? 7 : 30))
    }

    public func taskChangePercent(days: Int) -> Double? {
        let current = metrics(days: days).taskCount
        let previous = previousMetrics(days: days).taskCount
        guard previous > 0 else { return current == 0 ? 0 : nil }
        return Double(current - previous) / Double(previous) * 100
    }
}

public enum AntigravityStateProfile: String, Codable, CaseIterable, Hashable, Sendable {
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
