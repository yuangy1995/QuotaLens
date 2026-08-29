import AppKit
import SwiftUI

/// Displays the installed application icon for a monitored tool.
public struct ToolAppIcon: View {
    public let tool: MonitoringToolID
    public let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(tool: MonitoringToolID, size: CGFloat = 24) {
        self.tool = tool
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = Self.applicationImage(for: tool) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.22), style: .continuous))
            } else {
                Image(systemName: ToolRegistry.shared.descriptor(for: tool)?.systemImage ?? "app.fill")
                    .font(.system(size: size * 0.58, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary(for: colorScheme))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Returns a copy so a status item or SwiftUI view can size it independently.
    @MainActor
    public static func applicationImage(for tool: MonitoringToolID) -> NSImage? {
        let bundleIdentifiers: [String]
        let applicationPaths: [String]

        switch tool {
        case .codex:
            bundleIdentifiers = ["com.openai.codex", "com.openai.chat"]
            applicationPaths = ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
        case .claude:
            bundleIdentifiers = ["com.anthropic.claudefordesktop", "com.anthropic.Claude"]
            applicationPaths = ["/Applications/Claude.app", "/Applications/Claude Desktop.app"]
        case .antigravity:
            bundleIdentifiers = ["com.google.antigravity-ide", "com.google.antigravity"]
            applicationPaths = ["/Applications/Antigravity IDE.app", "/Applications/Antigravity.app"]
        default:
            return nil
        }

        for bundleIdentifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
               let image = icon(at: url) {
                return image
            }
        }

        for path in applicationPaths {
            if let image = icon(at: URL(fileURLWithPath: path)) {
                return image
            }
        }

        return nil
    }

    @MainActor
    private static func icon(at url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        guard image.isValid else { return nil }
        return image.copy() as? NSImage ?? image
    }
}
