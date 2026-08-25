// QuotaLens 科技风全息设计系统 (Dual Theme Design System)

import SwiftUI

// MARK: - 科技 HUD 分组标题 (CyberSectionHeader)
public struct CyberSectionHeader: View {
    @Environment(\.colorScheme) var colorScheme
    public var tag: String? = nil
    public let title: String
    public var subtitle: String? = nil
    public var icon: String? = nil

    public init(tag: String? = nil, title: String, subtitle: String? = nil, icon: String? = nil) {
        self.tag = tag
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
    }

    public var body: some View {
        let cyan = AppTheme.accentCyan(for: colorScheme)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(cyan)
                }

                if let tag, !tag.isEmpty {
                    Text(tag)
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(cyan)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(cyan.opacity(colorScheme == .dark ? 0.15 : 0.12), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(cyan.opacity(colorScheme == .dark ? 0.4 : 0.3), lineWidth: 0.8)
                        )
                }

                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary(for: colorScheme))

                Spacer()
            }

            if let sub = subtitle {
                Text(sub)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                    .padding(.leading, (tag?.isEmpty ?? true) ? 0 : 2)
            }
        }
    }
}

// MARK: - 高对比度科技风分段选择器 (CyberSegmentedPicker)
public struct CyberSegmentedPicker: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding public var selection: QuotaDisplayMode
    public var isFullWidth: Bool

    public init(selection: Binding<QuotaDisplayMode>, isFullWidth: Bool = false) {
        self._selection = selection
        self.isFullWidth = isFullWidth
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        let activeBlue = AppTheme.accentBlue(for: colorScheme)
        let activeCyan = AppTheme.accentCyan(for: colorScheme)

        HStack(spacing: 3) {
            ForEach(QuotaDisplayMode.allCases) { mode in
                let isSelected = selection == mode
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        selection = mode
                    }
                }) {
                    Text(mode.pickerTitle)
                        .font(.system(size: 12, weight: isSelected ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white : AppTheme.textSecondary(for: colorScheme))
                        .frame(maxWidth: isFullWidth ? .infinity : nil)
                        .padding(.horizontal, isFullWidth ? 4 : 14)
                        .padding(.vertical, 6)
                        .background(
                            ZStack {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [activeCyan, activeBlue],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .shadow(color: activeCyan.opacity(isDark ? 0.35 : 0.20), radius: 4)
                                } else {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.clear)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(maxWidth: isFullWidth ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isDark ? Color.black.opacity(0.35) : Color.black.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.8)
        )
    }
}

// MARK: - 科技 HUD 数据指标卡 (StatMetricCard)
public struct StatMetricCard: View {
    @Environment(\.colorScheme) var colorScheme
    public let title: String
    public let value: String
    public let subtitle: String
    public let icon: String
    public let color: Color

    public init(title: String, value: String, subtitle: String, icon: String, color: Color) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 26, height: 26)
                    .background(color.opacity(colorScheme == .dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(color.opacity(colorScheme == .dark ? 0.45 : 0.3), lineWidth: 0.8)
                    )

                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))

                Spacer()
            }

            Text(value)
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
                .monospacedDigit()

            Text(subtitle)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
                .lineLimit(1)
        }
        .cyberCard(cornerRadius: 12, padding: 14)
    }
}

// MARK: - 科技风分割线 (CyberDivider)
public struct CyberDivider: View {
    @Environment(\.colorScheme) var colorScheme
    public var glowColor: Color? = nil

    public init(glowColor: Color? = nil) {
        self.glowColor = glowColor
    }

    public var body: some View {
        let activeGlow = glowColor ?? AppTheme.accentCyan(for: colorScheme).opacity(colorScheme == .dark ? 0.3 : 0.2)
        let edgeColor = colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.02)

        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        edgeColor,
                        activeGlow,
                        edgeColor
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

// MARK: - 现代化模型徽标与图标
public struct ModelIconBadge: View {
    @Environment(\.colorScheme) var colorScheme
    public let model: String

    public init(model: String) {
        self.model = model
    }

    public var color: Color {
        AppTheme.colorForModel(model, scheme: colorScheme)
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.5), radius: 3)

            Text(model)
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
        }
    }
}

// MARK: - 科技风全息卡片容器组件
public struct CyberContainerCard<Content: View>: View {
    public let content: Content
    public var cornerRadius: CGFloat = 14
    public var padding: CGFloat = 16
    public var isHighlighted: Bool = false
    public var glowColor: Color? = nil

    public init(
        cornerRadius: CGFloat = 14,
        padding: CGFloat = 16,
        isHighlighted: Bool = false,
        glowColor: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.isHighlighted = isHighlighted
        self.glowColor = glowColor
        self.content = content()
    }

    public var body: some View {
        content
            .cyberCard(
                cornerRadius: cornerRadius,
                padding: padding,
                isHighlighted: isHighlighted,
                glowColor: glowColor
            )
    }
}

// MARK: - 推理级别徽章 (ReasoningEffortBadge)
public struct ReasoningEffortDisplay {
    public static func localizedName(for effort: String) -> String {
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "low":
            return L10n.text("低推理", "Low Reasoning")
        case "medium", "middle", "med":
            return L10n.text("中推理", "Medium Reasoning")
        case "high":
            return L10n.text("高推理", "High Reasoning")
        case "xhigh", "extra_high", "extra-high":
            return L10n.text("极高推理", "Extra High Reasoning")
        case "max":
            return L10n.text("最大推理", "Max Reasoning")
        case "ultra":
            return L10n.text("超级推理", "Ultra Reasoning")
        default:
            return effort
        }
    }

    public static func badgeText(for effort: String) -> String {
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "medium", "middle":
            return "medium"
        case "extra_high", "extra-high":
            return "xhigh"
        default:
            return normalized
        }
    }
}

public struct ReasoningEffortBadge: View {
    @Environment(\.colorScheme) var colorScheme
    public let effort: String

    public init(effort: String) {
        self.effort = effort
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let badgeColor: Color = {
            switch normalized {
            case "xhigh", "extra_high", "extra-high", "ultra", "max":
                return AppTheme.accentPurple(for: colorScheme)
            case "high":
                return Color.indigo
            case "medium", "middle", "med":
                return AppTheme.accentCyan(for: colorScheme)
            default:
                return AppTheme.textSecondary(for: colorScheme)
            }
        }()

        Text(ReasoningEffortDisplay.badgeText(for: effort))
            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(badgeColor.opacity(isDark ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(badgeColor.opacity(isDark ? 0.45 : 0.30), lineWidth: 0.6)
            )
            .help(L10n.format("Reasoning Effort: %@", zhHans: "推理级别：%@", ReasoningEffortDisplay.localizedName(for: effort)))
    }
}

// MARK: - 服务层级徽章 (ServiceTierBadge)
public struct ServiceTierBadge: View {
    @Environment(\.colorScheme) var colorScheme
    public let tier: String

    public init(tier: String) {
        self.tier = tier
    }

    public static func shouldDisplay(_ tier: String?) -> Bool {
        guard let tier else { return false }
        let lower = tier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !lower.isEmpty && lower != "default" && lower != "standard"
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        let amber = AppTheme.accentAmber(for: colorScheme)
        Text(tier.uppercased())
            .font(.system(size: 8.5, weight: .black, design: .monospaced))
            .foregroundStyle(amber)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(amber.opacity(isDark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(amber.opacity(isDark ? 0.40 : 0.25), lineWidth: 0.6)
            )
    }
}


