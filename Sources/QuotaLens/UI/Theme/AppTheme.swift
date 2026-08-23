// QuotaLens 科技风视觉设计系统与全息主题配置 (Dual Theme: Crystal Light & Cyber Dark)

import SwiftUI

public struct AppTheme {
    // MARK: - 动态语义文本色
    public static func textPrimary(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.98, green: 0.99, blue: 1.0) : Color(red: 0.07, green: 0.09, blue: 0.15)
    }

    public static func textSecondary(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.84, green: 0.89, blue: 0.97) : Color(red: 0.28, green: 0.33, blue: 0.42)
    }

    public static func textMuted(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.66, green: 0.74, blue: 0.86) : Color(red: 0.45, green: 0.52, blue: 0.62)
    }

    // 默认高频调用常量 (向后兼容)
    public static let neonCyan = Color(red: 0.0, green: 0.92, blue: 1.0)
    public static let neonBlue = Color(red: 0.25, green: 0.60, blue: 1.0)
    public static let neonEmerald = Color(red: 0.10, green: 0.90, blue: 0.58)
    public static let neonAmber = Color(red: 1.0, green: 0.70, blue: 0.15)
    public static let neonPurple = Color(red: 0.72, green: 0.42, blue: 1.0)
    public static let neonRose = Color(red: 1.0, green: 0.30, blue: 0.45)

    // MARK: - 动态核心科技强调色
    public static func accentCyan(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.0, green: 0.92, blue: 1.0) : Color(red: 0.01, green: 0.52, blue: 0.82)
    }

    public static func accentBlue(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.25, green: 0.60, blue: 1.0) : Color(red: 0.12, green: 0.44, blue: 0.88)
    }

    public static func accentEmerald(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.10, green: 0.90, blue: 0.58) : Color(red: 0.02, green: 0.60, blue: 0.40)
    }

    public static func accentAmber(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1.0, green: 0.70, blue: 0.15) : Color(red: 0.85, green: 0.46, blue: 0.02)
    }

    public static func accentPurple(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.72, green: 0.42, blue: 1.0) : Color(red: 0.48, green: 0.22, blue: 0.92)
    }

    public static func accentRose(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1.0, green: 0.30, blue: 0.45) : Color(red: 0.88, green: 0.12, blue: 0.28)
    }

    // MARK: - 动态背景与画布表面色
    public static func canvasGradient(for scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.12), Color(red: 0.035, green: 0.045, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [Color(red: 0.95, green: 0.965, blue: 0.985), Color(red: 0.91, green: 0.935, blue: 0.965)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    public static func sidebarGradient(for scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [Color(red: 0.07, green: 0.08, blue: 0.14), Color(red: 0.05, green: 0.06, blue: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [Color(red: 0.93, green: 0.945, blue: 0.97), Color(red: 0.89, green: 0.915, blue: 0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    public static func popoverGradient(for scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [Color(red: 0.08, green: 0.10, blue: 0.17), Color(red: 0.05, green: 0.06, blue: 0.11)],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [Color(red: 0.97, green: 0.98, blue: 0.99), Color(red: 0.92, green: 0.94, blue: 0.97)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    public static func insetSurface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.30) : Color.black.opacity(0.04)
    }

    public static func insetBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    // MARK: - 动态全息边框渐变
    public static func cardBorderGradient(for scheme: ColorScheme, isHighlighted: Bool) -> LinearGradient {
        if scheme == .dark {
            if isHighlighted {
                return LinearGradient(
                    colors: [
                        neonCyan.opacity(0.65),
                        neonBlue.opacity(0.25),
                        neonPurple.opacity(0.45),
                        neonCyan.opacity(0.3)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                return LinearGradient(
                    colors: [
                        Color.white.opacity(0.24),
                        Color.white.opacity(0.08),
                        neonCyan.opacity(0.20),
                        Color.white.opacity(0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            if isHighlighted {
                return LinearGradient(
                    colors: [
                        accentCyan(for: .light).opacity(0.55),
                        accentPurple(for: .light).opacity(0.35),
                        accentBlue(for: .light).opacity(0.45)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                return LinearGradient(
                    colors: [
                        Color.black.opacity(0.12),
                        Color.black.opacity(0.05),
                        accentCyan(for: .light).opacity(0.15),
                        Color.black.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    // 模型专属强调色
    public static func colorForModel(_ model: String, scheme: ColorScheme = .dark) -> Color {
        let lower = model.lowercased()
        if lower.contains("sol") {
            return accentAmber(for: scheme)
        } else if lower.contains("terra") {
            return accentCyan(for: scheme)
        } else if lower.contains("luna") {
            return accentPurple(for: scheme)
        } else if lower.contains("未归因") || lower.contains("unattributed") {
            return Color.gray
        } else {
            return accentBlue(for: scheme)
        }
    }
}

// MARK: - 科技 HUD 发光修饰器
public struct CyberGlowModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    public var color: Color? = nil
    public var radius: CGFloat = 6
    public var opacity: Double = 0.45

    public func body(content: Content) -> some View {
        let targetColor = color ?? AppTheme.accentCyan(for: colorScheme)
        content
            .shadow(color: targetColor.opacity(colorScheme == .dark ? opacity : opacity * 0.6), radius: radius, x: 0, y: 0)
    }
}

// MARK: - 科技感全息卡片 Modifier (自动支持浅色晶透与深色黑曜石)
public struct CyberCardModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    public var cornerRadius: CGFloat = 14
    public var padding: CGFloat = 18
    public var isHighlighted: Bool = false
    public var glowColor: Color? = nil

    public func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let activeGlowColor = glowColor ?? AppTheme.accentCyan(for: colorScheme)

        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isDark ? [
                                Color(red: 0.105, green: 0.135, blue: 0.215).opacity(0.96),
                                Color(red: 0.075, green: 0.095, blue: 0.155).opacity(0.94)
                            ] : [
                                Color.white.opacity(0.94),
                                Color(red: 0.97, green: 0.985, blue: 1.0).opacity(0.90)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        AnyShapeStyle(AppTheme.cardBorderGradient(for: colorScheme, isHighlighted: isHighlighted)),
                        lineWidth: isHighlighted ? 1.4 : 1.0
                    )
            )
            .shadow(
                color: isDark ? (isHighlighted ? activeGlowColor.opacity(0.24) : Color.black.opacity(0.32))
                              : (isHighlighted ? activeGlowColor.opacity(0.18) : Color.black.opacity(0.06)),
                radius: isHighlighted ? 14 : 9,
                x: 0,
                y: isHighlighted ? 4 : 2.5
            )
            .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
    }
}

public extension View {
    func cyberCard(
        cornerRadius: CGFloat = 14,
        padding: CGFloat = 18,
        isHighlighted: Bool = false,
        glowColor: Color? = nil
    ) -> some View {
        self.modifier(CyberCardModifier(
            cornerRadius: cornerRadius,
            padding: padding,
            isHighlighted: isHighlighted,
            glowColor: glowColor
        ))
    }

    func glassCard(cornerRadius: CGFloat = 14, isHighlighted: Bool = false) -> some View {
        self.modifier(CyberCardModifier(cornerRadius: cornerRadius, padding: 16, isHighlighted: isHighlighted))
    }

    func modernCard(cornerRadius: CGFloat = 14, padding: CGFloat = 18) -> some View {
        self.modifier(CyberCardModifier(cornerRadius: cornerRadius, padding: padding, isHighlighted: false))
    }

    func cyberGlow(color: Color? = nil, radius: CGFloat = 6, opacity: Double = 0.5) -> some View {
        self.modifier(CyberGlowModifier(color: color, radius: radius, opacity: opacity))
    }
}
