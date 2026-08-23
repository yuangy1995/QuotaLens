// QuotaLens 科技风脉冲状态指示信标 (Dual Theme Pulsing Beacon)

import SwiftUI

public struct StatusBadge: View {
    @Environment(\.colorScheme) var colorScheme
    public let text: String
    public let color: Color?
    public let icon: String
    public var isPulsing: Bool = false
    private let statusKind: StatusKind?

    public enum StatusKind {
        case connected
        case connecting
        case disconnected
        case failed
    }

    public init(text: String, color: Color, icon: String, isPulsing: Bool = false) {
        self.text = text
        self.color = color
        self.icon = icon
        self.isPulsing = isPulsing
        self.statusKind = nil
    }

    private init(kind: StatusKind) {
        self.statusKind = kind
        self.color = nil
        self.isPulsing = (kind == .connected || kind == .connecting)
        switch kind {
        case .connected:
            self.text = L10n.text("已连接", "Connected")
            self.icon = "antenna.radiowaves.left.and.right"
        case .connecting:
            self.text = L10n.text("连接中", "Connecting")
            self.icon = "arrow.triangle.2.circlepath"
        case .disconnected:
            self.text = L10n.text("未连接", "Offline")
            self.icon = "circle.slash"
        case .failed:
            self.text = L10n.text("连接断开", "Disconnected")
            self.icon = "xmark.octagon.fill"
        }
    }

    private var resolvedColor: Color {
        if let color { return color }
        guard let statusKind else { return AppTheme.accentEmerald(for: colorScheme) }
        switch statusKind {
        case .connected: return AppTheme.accentEmerald(for: colorScheme)
        case .connecting: return AppTheme.accentAmber(for: colorScheme)
        case .disconnected: return colorScheme == .dark ? Color.secondary : Color(red: 0.45, green: 0.50, blue: 0.58)
        case .failed: return AppTheme.accentRose(for: colorScheme)
        }
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        let activeColor = resolvedColor

        HStack(spacing: 6) {
            // 发光呼吸指示圆点 / 科技图标
            ZStack {
                Circle()
                    .fill(activeColor.opacity(isDark ? 0.35 : 0.25))
                    .frame(width: 8, height: 8)
                    .blur(radius: 2)

                Circle()
                    .fill(activeColor)
                    .frame(width: 5, height: 5)
            }

            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(activeColor)

            Text(text)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(activeColor)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(activeColor.opacity(isDark ? 0.12 : 0.10))
        )
        .overlay(
            Capsule()
                .strokeBorder(activeColor.opacity(isDark ? 0.35 : 0.25), lineWidth: 1)
        )
        .shadow(color: activeColor.opacity(isDark ? 0.18 : 0.08), radius: 4, x: 0, y: 1)
    }

    public static func forConnection(_ status: ProcessStatus) -> StatusBadge {
        switch status {
        case .connected(_, _):
            return StatusBadge(kind: .connected)
        case .connecting:
            return StatusBadge(kind: .connecting)
        case .disconnected:
            return StatusBadge(kind: .disconnected)
        case .failed:
            return StatusBadge(kind: .failed)
        }
    }
}
