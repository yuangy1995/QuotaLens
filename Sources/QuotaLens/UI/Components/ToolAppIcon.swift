import AppKit
import SwiftUI

/// Displays the installed application icon, with a built-in Claude fallback.
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

        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let candidatePaths = applicationPaths + applicationPaths.map {
            userApplications.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent).path
        }
        for path in candidatePaths {
            if let image = icon(at: URL(fileURLWithPath: path)) {
                return image
            }
        }

        return fallbackImage(for: tool)
    }

    /// A resolution-independent Claude-inspired sunburst, available offline.
    @MainActor
    static func fallbackImage(for tool: MonitoringToolID) -> NSImage? {
        guard tool == .claude else { return nil }
        return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor(srgbRed: 0.98, green: 0.95, blue: 0.91, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 27, yRadius: 27).fill()

            NSColor(srgbRed: 0.78, green: 0.38, blue: 0.25, alpha: 1).setFill()
            let mark = NSBezierPath()
            let lengths: [CGFloat] = [43, 40, 45, 39, 44, 41, 45, 40, 44, 42, 40, 45]
            for index in 0..<12 {
                let angle = CGFloat(index) * .pi / 6
                let vertices: [(CGFloat, CGFloat)] = [(-0.22, 13), (-0.075, lengths[index]),
                                                     (0.075, lengths[index] - 1), (0.22, 13)]
                for (offset, radius) in vertices {
                    let point = NSPoint(x: 64 + cos(angle + offset) * radius,
                                        y: 64 + sin(angle + offset) * radius)
                    if index == 0 && offset == -0.22 { mark.move(to: point) }
                    else { mark.line(to: point) }
                }
            }
            mark.close()
            mark.fill()
            return true
        }
    }

    @MainActor
    private static func icon(at url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        guard image.isValid else { return nil }
        return image.copy() as? NSImage ?? image
    }
}
