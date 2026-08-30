import Foundation

struct WeeklyQuotaPoolKey: Codable, Hashable, Sendable {
    let tool: MonitoringToolID
    let accountKey: String
    let poolID: String

    var storageKey: String {
        "\(tool.rawValue)|\(accountKey)|\(poolID)"
    }
}

struct WeeklyQuotaPoolSample: Codable, Equatable, Sendable {
    let key: WeeklyQuotaPoolKey
    let displayName: String?
    let remainingPercent: Double
    let resetAt: Date?
    let capturedAt: Date

    init(
        key: WeeklyQuotaPoolKey,
        displayName: String?,
        remainingPercent: Double,
        resetAt: Date?,
        capturedAt: Date
    ) {
        self.key = key
        self.displayName = displayName
        self.remainingPercent = min(max(remainingPercent, 0), 100)
        self.resetAt = resetAt
        self.capturedAt = capturedAt
    }
}

struct WeeklyQuotaRecoveryItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let tool: MonitoringToolID
    let displayName: String
    let recoveredAt: Date
}

struct WeeklyQuotaRecoveryPersistence: Codable, Sendable {
    var samples: [String: WeeklyQuotaPoolSample] = [:]
    var unreadItems: [WeeklyQuotaRecoveryItem] = []
}

enum WeeklyQuotaRecoveryDetector {
    static let recoveryThreshold = 99.99
    static let offlineRecoveryWindow: TimeInterval = 24 * 60 * 60

    static func isRecovery(
        previous: WeeklyQuotaPoolSample?,
        current: WeeklyQuotaPoolSample,
        isFirstComparisonForAccount: Bool,
        now: Date
    ) -> Bool {
        guard let previous,
              previous.key == current.key,
              previous.remainingPercent < recoveryThreshold,
              current.remainingPercent >= recoveryThreshold else {
            return false
        }

        guard isFirstComparisonForAccount else { return true }
        guard let resetAt = previous.resetAt else { return false }
        let elapsed = now.timeIntervalSince(resetAt)
        return elapsed >= 0 && elapsed <= offlineRecoveryWindow
    }

    static func detect(
        previous: [String: WeeklyQuotaPoolSample],
        current: [WeeklyQuotaPoolSample],
        isFirstComparisonForAccount: Bool,
        now: Date
    ) -> [WeeklyQuotaRecoveryItem] {
        var seen = Set<String>()
        return current.compactMap { sample in
            guard seen.insert(sample.key.storageKey).inserted,
                  isRecovery(
                      previous: previous[sample.key.storageKey],
                      current: sample,
                      isFirstComparisonForAccount: isFirstComparisonForAccount,
                      now: now
                  ) else {
                return nil
            }

            let displayName = sample.displayName.map { "\(toolName(sample.key.tool)) · \($0)" }
                ?? toolName(sample.key.tool)
            let recoveryID = "\(sample.key.storageKey)|\(Int64(sample.capturedAt.timeIntervalSince1970 * 1_000))"
            return WeeklyQuotaRecoveryItem(
                id: recoveryID,
                tool: sample.key.tool,
                displayName: displayName,
                recoveredAt: sample.capturedAt
            )
        }
    }

    private static func toolName(_ tool: MonitoringToolID) -> String {
        switch tool {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        default: return tool.rawValue
        }
    }
}
