import Foundation

public enum ToolPage: String, CaseIterable, Identifiable, Sendable {
    case quota
    case usage
    case history
    case sessions
    case resetCards
    case settings

    public var id: String { rawValue }

    public var capability: ToolCapability {
        switch self {
        case .quota: return .quota
        case .usage: return .usage
        case .history: return .history
        case .sessions: return .sessions
        case .resetCards: return .resetCards
        case .settings: return .settings
        }
    }

    public var title: String {
        switch self {
        case .quota: return L10n.text("额度概览", "Quota Overview")
        case .usage: return L10n.text("用量分析", "Usage Analytics")
        case .history: return L10n.text("历史记录", "History")
        case .sessions: return L10n.text("会话明细", "Sessions")
        case .resetCards: return L10n.text("重置卡", "Reset Cards")
        case .settings: return L10n.text("工具设置", "Tool Settings")
        }
    }

    public var icon: String {
        switch self {
        case .quota: return "gauge.with.needle.fill"
        case .usage: return "chart.bar.xaxis"
        case .history: return "calendar.badge.clock"
        case .sessions: return "bubble.left.and.bubble.right.fill"
        case .resetCards: return "ticket.fill"
        case .settings: return "slider.horizontal.3"
        }
    }
}

public enum FixedNavigationDestination: String, Sendable {
    case appSettings
    case about

    public var title: String {
        switch self {
        case .appSettings: return L10n.text("应用设置", "App Settings")
        case .about: return L10n.text("关于", "About")
        }
    }

    public var icon: String {
        switch self {
        case .appSettings: return "gearshape.2.fill"
        case .about: return "info.circle.fill"
        }
    }
}

@MainActor
public final class AppNavigationStore: ObservableObject {
    private static let contextDefaultsKey = "QuotaLens.Navigation.Context.v1"
    private static let fixedDestinationDefaultsKey = "QuotaLens.Navigation.FixedDestination.v1"
    private static let routeDefaultsPrefix = "QuotaLens.Navigation.ToolPage.v1"

    @Published public private(set) var selectedContext: AppContext
    @Published public private(set) var fixedDestination: FixedNavigationDestination?
    @Published private var toolPages: [MonitoringToolID: ToolPage]

    public init(enabledTools: EnabledToolsStore, activeTool: MonitoringToolID?, defaults: UserDefaults = .standard) {
        let enabled = enabledTools.enabledToolIDs
        if let stored = defaults.string(forKey: Self.contextDefaultsKey),
           let context = AppContext(storageValue: stored),
           Self.isValid(context, enabled: enabled) {
            selectedContext = context
        } else if let activeTool, enabled.contains(activeTool) {
            selectedContext = .tool(activeTool)
        } else if enabled.count == 1, let only = enabled.first {
            selectedContext = .tool(only)
        } else {
            selectedContext = .overview
        }
        fixedDestination = defaults.string(forKey: Self.fixedDestinationDefaultsKey)
            .flatMap(FixedNavigationDestination.init(rawValue:))

        var pages: [MonitoringToolID: ToolPage] = [:]
        for descriptor in ToolRegistry.shared.descriptors {
            let key = Self.routeDefaultsPrefix + "." + descriptor.id.rawValue
            let stored = defaults.string(forKey: key).flatMap(ToolPage.init(rawValue:)) ?? .quota
            pages[descriptor.id] = descriptor.capabilities.contains(stored.capability) ? stored : .quota
        }
        toolPages = pages
    }

    public func selectedPage(for tool: MonitoringToolID) -> ToolPage {
        toolPages[tool] ?? .quota
    }

    public func selectContext(_ context: AppContext) {
        selectedContext = context
        fixedDestination = nil
        UserDefaults.standard.set(context.storageValue, forKey: Self.contextDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.fixedDestinationDefaultsKey)
    }

    public func selectToolPage(_ page: ToolPage, for tool: MonitoringToolID) {
        guard ToolRegistry.shared.descriptor(for: tool)?.capabilities.contains(page.capability) == true else { return }
        toolPages[tool] = page
        fixedDestination = nil
        UserDefaults.standard.set(page.rawValue, forKey: Self.routeDefaultsPrefix + "." + tool.rawValue)
        UserDefaults.standard.removeObject(forKey: Self.fixedDestinationDefaultsKey)
    }

    public func showFixedDestination(_ destination: FixedNavigationDestination) {
        fixedDestination = destination
        UserDefaults.standard.set(destination.rawValue, forKey: Self.fixedDestinationDefaultsKey)
    }

    public func normalize(enabledTools: Set<MonitoringToolID>, activeTool: MonitoringToolID?) {
        if case .tool(let id) = selectedContext, !enabledTools.contains(id) {
            if let activeTool, enabledTools.contains(activeTool) {
                selectContext(.tool(activeTool))
            } else if enabledTools.count == 1, let only = enabledTools.first {
                selectContext(.tool(only))
            } else {
                selectContext(.overview)
            }
        } else if enabledTools.count == 1,
                  selectedContext == .overview,
                  let only = enabledTools.first {
            selectContext(.tool(only))
        }
        if enabledTools.isEmpty {
            selectedContext = .overview
        }
    }

    private static func isValid(_ context: AppContext, enabled: Set<MonitoringToolID>) -> Bool {
        switch context {
        case .overview:
            return enabled.count != 1
        case .tool(let id):
            return enabled.contains(id)
        }
    }
}
