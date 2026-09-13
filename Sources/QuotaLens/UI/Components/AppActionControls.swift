import SwiftUI

/// Matches the app's cyan action buttons and rounded, blue-gradient selection chips.
struct AppActionSurface: ViewModifier {
    var pressed = false
    var destructive = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        let tint = destructive ? AppTheme.accentRose(for: scheme) : AppTheme.accentCyan(for: scheme)
        content
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(pressed ? 0.19 : scheme == .dark ? 0.12 : 0.06),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tint.opacity(scheme == .dark ? 0.22 : 0.10), lineWidth: 0.6))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct AppActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(AppActionSurface(pressed: configuration.isPressed,
                                                      destructive: configuration.role == .destructive))
    }
}

struct AppSegmentedPicker<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [Selection]
    let title: (Selection) -> String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: selected ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(selected ? Color.white : AppTheme.textSecondary(for: scheme))
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity).padding(.horizontal, 8).padding(.vertical, 6)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(LinearGradient(colors: [AppTheme.accentCyan(for: scheme), AppTheme.accentBlue(for: scheme)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(scheme == .dark ? Color.black.opacity(0.25) : Color.black.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(AppTheme.insetBorder(for: scheme), lineWidth: 0.8))
    }
}
