// QuotaLens 额度窗口类型

import Foundation

public enum QuotaWindowKind: String, Hashable, Sendable {
    case fiveHour = "five_hour"
    case weekly = "weekly"

    /// 当前服务端只明确区分 5 小时窗口与周窗口；未知值沿用周窗口行为。
    public init(windowDurationMins: Int?) {
        self = windowDurationMins == 300 ? .fiveHour : .weekly
    }

    public var paceUnitSeconds: TimeInterval {
        switch self {
        case .fiveHour:
            return 3_600
        case .weekly:
            return 86_400
        }
    }
}
