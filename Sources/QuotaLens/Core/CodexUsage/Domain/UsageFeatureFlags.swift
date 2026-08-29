// QuotaLens 用量分析特性开关与配置持久化

import Foundation
import Combine

public final class UsageFeatureFlags: ObservableObject, @unchecked Sendable {
    public static let shared = UsageFeatureFlags()

    private static let analyticsEnabledKey = "QuotaLens.Analytics.Enabled"
    private static let overlayEnabledKey = "QuotaLens.Overlay.Enabled"
    private static let forecastEnabledKey = "QuotaLens.Forecast.Enabled"
    private static let scanArchivedSessionsKey = "QuotaLens.Analytics.ScanArchivedSessions"
    private static let customCodexHomePathKey = "QuotaLens.Analytics.CustomCodexHomePath"
    private static let axSnappingEnabledKey = "QuotaLens.Overlay.AXSnappingEnabled"
    private static let legacyOverlayVisibilityKey = "QuotaLens.Overlay.OnlyWhenActive"

    @Published public var isAnalyticsEnabled: Bool {
        didSet { UserDefaults.standard.set(isAnalyticsEnabled, forKey: Self.analyticsEnabledKey) }
    }

    @Published public var isOverlayEnabled: Bool {
        didSet { UserDefaults.standard.set(isOverlayEnabled, forKey: Self.overlayEnabledKey) }
    }

    @Published public var isForecastEnabled: Bool {
        didSet { UserDefaults.standard.set(isForecastEnabled, forKey: Self.forecastEnabledKey) }
    }

    @Published public var isScanArchivedSessionsEnabled: Bool {
        didSet { UserDefaults.standard.set(isScanArchivedSessionsEnabled, forKey: Self.scanArchivedSessionsKey) }
    }

    @Published public var customCodexHomePath: String? {
        didSet {
            if let customCodexHomePath, !customCodexHomePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.set(customCodexHomePath, forKey: Self.customCodexHomePathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.customCodexHomePathKey)
            }
        }
    }

    @Published public var isAXSnappingEnabled: Bool {
        didSet { UserDefaults.standard.set(isAXSnappingEnabled, forKey: Self.axSnappingEnabledKey) }
    }

    public init() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.legacyOverlayVisibilityKey)
        if defaults.object(forKey: Self.analyticsEnabledKey) == nil {
            self.isAnalyticsEnabled = true
        } else {
            self.isAnalyticsEnabled = defaults.bool(forKey: Self.analyticsEnabledKey)
        }

        if defaults.object(forKey: Self.overlayEnabledKey) == nil {
            self.isOverlayEnabled = true
            defaults.set(true, forKey: Self.overlayEnabledKey)
        } else {
            self.isOverlayEnabled = defaults.bool(forKey: Self.overlayEnabledKey)
        }

        if defaults.object(forKey: Self.forecastEnabledKey) == nil {
            self.isForecastEnabled = true
        } else {
            self.isForecastEnabled = defaults.bool(forKey: Self.forecastEnabledKey)
        }

        if defaults.object(forKey: Self.scanArchivedSessionsKey) == nil {
            self.isScanArchivedSessionsEnabled = true
        } else {
            self.isScanArchivedSessionsEnabled = defaults.bool(forKey: Self.scanArchivedSessionsKey)
        }

        self.customCodexHomePath = defaults.string(forKey: Self.customCodexHomePathKey)
        self.isAXSnappingEnabled = defaults.bool(forKey: Self.axSnappingEnabledKey)
    }
}
