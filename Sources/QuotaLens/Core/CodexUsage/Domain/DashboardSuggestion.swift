// QuotaLens 首页智能建议模型定义 (Dashboard Suggestion Models)

import Foundation

public enum DashboardSuggestionID: String, Sendable, Hashable {
    case useResetCardWhenExhausted = "use_reset_card_when_exhausted"
}

public struct DashboardSuggestion: Identifiable, Sendable {
    public let id: DashboardSuggestionID
    public let title: String
    public let message: String
    public let icon: String
    public let primaryActionTitle: String
    public let dismissActionTitle: String
    public let payload: Payload?

    public enum Payload: Sendable {
        case resetCredit(ResetCreditDisplay)
    }

    public init(
        id: DashboardSuggestionID,
        title: String,
        message: String,
        icon: String = "sparkles",
        primaryActionTitle: String,
        dismissActionTitle: String,
        payload: Payload? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.icon = icon
        self.primaryActionTitle = primaryActionTitle
        self.dismissActionTitle = dismissActionTitle
        self.payload = payload
    }
}
