// QuotaLens 全息科技感线性进度条组件 (Cyber Linear Progress Bar & Scanner Indicator)

import SwiftUI

// MARK: - 科技感线性进度条 (CyberProgressBar)
public struct CyberProgressBar: View {
    @Environment(\.colorScheme) private var colorScheme
    public var value: Double? // 0.0 ~ 1.0, nil 表示不确定进度的扫描状态
    public var height: CGFloat
    public var accentColor: Color?
    public var glowColor: Color?
    public var showBeacon: Bool

    @State private var isIndeterminateAnimating: Bool = false

    public init(
        value: Double?,
        height: CGFloat = 5,
        accentColor: Color? = nil,
        glowColor: Color? = nil,
        showBeacon: Bool = true
    ) {
        self.value = value
        self.height = height
        self.accentColor = accentColor
        self.glowColor = glowColor
        self.showBeacon = showBeacon
    }

    private var activeAccent: Color {
        accentColor ?? AppTheme.accentCyan(for: colorScheme)
    }

    private var activeGlow: Color {
        glowColor ?? activeAccent
    }

    public var body: some View {
        let isDark = colorScheme == .dark

        GeometryReader { proxy in
            let totalWidth = proxy.size.width

            ZStack(alignment: .leading) {
                // 1. 底层凹槽轨道
                Capsule()
                    .fill(isDark ? Color.black.opacity(0.40) : Color.black.opacity(0.07))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                                lineWidth: 0.8
                            )
                    )

                if let val = value {
                    // 2. 确定进度渲染
                    let clamped = max(0.0, min(1.0, val))
                    let barWidth = max(0, totalWidth * CGFloat(clamped))

                    if barWidth > 0 {
                        // 渐变主体
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        activeAccent.opacity(0.85),
                                        activeAccent,
                                        AppTheme.accentBlue(for: colorScheme)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: barWidth)
                            .shadow(color: activeGlow.opacity(isDark ? 0.45 : 0.25), radius: 4, x: 0, y: 0)

                        // 头部高亮信标光点
                        if showBeacon && clamped > 0.02 && clamped < 0.99 {
                            Circle()
                                .fill(Color.white)
                                .frame(width: height + 2, height: height + 2)
                                .shadow(color: activeGlow, radius: 3)
                                .offset(x: max(0, barWidth - (height + 2) / 2))
                        }
                    }
                } else {
                    // 3. 不确定进度动态扫描波
                    let beamWidth = max(28, totalWidth * 0.32)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    activeAccent.opacity(0),
                                    activeAccent.opacity(0.65),
                                    Color.white.opacity(0.95),
                                    activeAccent.opacity(0.65),
                                    activeAccent.opacity(0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: beamWidth)
                        .offset(x: isIndeterminateAnimating ? totalWidth - beamWidth : 0)
                        .shadow(color: activeGlow.opacity(isDark ? 0.6 : 0.35), radius: 4)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                                isIndeterminateAnimating = true
                            }
                        }
                }
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: value)
    }
}

// MARK: - 科技感扫描状态微徽标 (CyberScanIndicator)
public struct CyberScanIndicator: View {
    @Environment(\.colorScheme) private var colorScheme
    public var size: CGFloat
    public var accentColor: Color?
    @State private var isRotating: Bool = false

    public init(size: CGFloat = 18, accentColor: Color? = nil) {
        self.size = size
        self.accentColor = accentColor
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        let tint = accentColor ?? AppTheme.accentCyan(for: colorScheme)

        ZStack {
            Circle()
                .fill(tint.opacity(isDark ? 0.16 : 0.10))
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .strokeBorder(tint.opacity(isDark ? 0.38 : 0.24), lineWidth: 0.8)
                )

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: size * 0.52, weight: .bold))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(isRotating ? 360 : 0))
                .onAppear {
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        isRotating = true
                    }
                }
        }
        .frame(width: size, height: size)
    }
}
