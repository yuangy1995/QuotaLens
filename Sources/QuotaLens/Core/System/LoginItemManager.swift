// macOS login item integration for launching QuotaLens after sign-in.

import Foundation
import ServiceManagement

public struct LoginItemState: Sendable {
    public let isEnabled: Bool
    public let description: String
}

@MainActor
public enum LoginItemManager {
    public static func currentState() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return LoginItemState(isEnabled: true, description: L10n.text("已开启", "On"))
        case .requiresApproval:
            return LoginItemState(isEnabled: false, description: L10n.text("需要在系统设置中确认", "Requires approval in System Settings"))
        case .notRegistered:
            return LoginItemState(isEnabled: false, description: L10n.text("未开启", "Off"))
        case .notFound:
            return LoginItemState(isEnabled: false, description: L10n.text("未开启", "Off"))
        @unknown default:
            return LoginItemState(isEnabled: false, description: L10n.text("状态未知", "Unknown"))
        }
    }

    public static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else if service.status == .enabled {
            try service.unregister()
        }
    }
}
