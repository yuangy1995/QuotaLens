import AppKit
import CoreGraphics

struct CodexOverlayWindow: Equatable, Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    let layer: Int
    let alpha: CGFloat
    let quartzFrame: CGRect
    var title: String? = nil
}

struct CodexOverlayDisplay: Equatable, Sendable {
    let quartzFrame: CGRect
    let appKitFrame: CGRect
}

struct CodexOverlayRelativePosition: Equatable, Sendable {
    let horizontal: CGFloat
    let vertical: CGFloat

    init(horizontal: CGFloat, vertical: CGFloat) {
        self.horizontal = min(1, max(0, horizontal))
        self.vertical = min(1, max(0, vertical))
    }
}

enum CodexOverlayWindowLocator {
    static let bundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.codex"
    ]
    private static let minimumWindowSize = CGSize(width: 420, height: 300)

    static func supportsBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(bundleIdentifiers.contains) ?? false
    }

    static func isCodex(_ application: NSRunningApplication?) -> Bool {
        supportsBundleIdentifier(application?.bundleIdentifier)
            && application?.isTerminated == false
    }

    static func runningProcessIDs(in workspace: NSWorkspace = .shared) -> Set<pid_t> {
        Set(workspace.runningApplications.compactMap { application in
            isCodex(application) ? application.processIdentifier : nil
        })
    }

    static func visibleWindows() -> [CodexOverlayWindow] {
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return rows.compactMap { row in
            guard let number = row[kCGWindowNumber as String] as? NSNumber,
                  let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = row[kCGWindowLayer as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(
                    dictionaryRepresentation: bounds as CFDictionary
                  ) else {
                return nil
            }
            let alpha = (row[kCGWindowAlpha as String] as? NSNumber)
                .map { CGFloat(truncating: $0) } ?? 1
            return CodexOverlayWindow(
                windowID: CGWindowID(number.uint32Value),
                processID: pid_t(owner.int32Value),
                layer: layer.intValue,
                alpha: alpha,
                quartzFrame: frame,
                title: row[kCGWindowName as String] as? String
            )
        }
    }

    static func selectWindow(
        processIDs: Set<pid_t>,
        focusedProcessID: pid_t?,
        previousWindowID: CGWindowID?,
        windows: [CodexOverlayWindow],
        excludingComputerUseWindows: Bool = false
    ) -> CodexOverlayWindow? {
        let candidates = windows.filter { window in
            processIDs.contains(window.processID)
                && window.layer == 0
                && window.alpha > 0.01
                && window.quartzFrame.width >= minimumWindowSize.width
                && window.quartzFrame.height >= minimumWindowSize.height
        }
        let eligible = candidates.filter { window in
            guard excludingComputerUseWindows else { return true }
            // 画中画及其控制层也是普通层级窗口，但不能作为额度挂件的宿主。
            if let title = window.title, !title.isEmpty {
                return !["Computer Use", "Computer Use Controls"].contains(title)
            }
            // 无屏幕录制权限时系统可能隐藏标题；小型附属窗口允许少量越出主窗口。
            let area = window.quartzFrame.width * window.quartzFrame.height
            return !candidates.contains { other in
                other.processID == window.processID
                    && other.windowID != window.windowID
                    && other.quartzFrame.width > window.quartzFrame.width
                    && other.quartzFrame.height > window.quartzFrame.height
                    && other.quartzFrame.width * other.quartzFrame.height >= area * 2
                    && overlapArea(window.quartzFrame, other.quartzFrame) >= area * 0.9
            }
        }

        if let focusedProcessID,
           let focusedWindow = eligible.first(where: {
               $0.processID == focusedProcessID
           }) {
            return focusedWindow
        }
        if let previousWindowID,
           let previousWindow = eligible.first(where: {
               $0.windowID == previousWindowID
           }) {
            return previousWindow
        }
        return eligible.first
    }

    static func isWindow(
        _ windowID: CGWindowID,
        above targetWindowID: CGWindowID,
        windows: [CodexOverlayWindow]
    ) -> Bool {
        guard let windowIndex = windows.firstIndex(where: {
            $0.windowID == windowID
        }), let targetIndex = windows.firstIndex(where: {
            $0.windowID == targetWindowID
        }) else {
            return false
        }
        return windowIndex < targetIndex
    }

    static func displaySpaces() -> [CodexOverlayDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            return CodexOverlayDisplay(
                quartzFrame: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)),
                appKitFrame: screen.frame
            )
        }
    }

    static func appKitFrame(
        from quartzFrame: CGRect,
        displays: [CodexOverlayDisplay]
    ) -> CGRect? {
        guard let display = displays.max(by: {
            overlapArea(quartzFrame, $0.quartzFrame)
                < overlapArea(quartzFrame, $1.quartzFrame)
        }), overlapArea(quartzFrame, display.quartzFrame) > 0 else {
            return nil
        }

        let xOffset = quartzFrame.minX - display.quartzFrame.minX
        let yOffset = quartzFrame.minY - display.quartzFrame.minY
        return CGRect(
            x: display.appKitFrame.minX + xOffset,
            y: display.appKitFrame.maxY - yOffset - quartzFrame.height,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }

    private static func overlapArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let overlap = first.intersection(second)
        guard !overlap.isNull else { return 0 }
        return overlap.width * overlap.height
    }
}

enum CodexOverlayLayout {
    private static let sidebarWidth: CGFloat = 438
    private static let helpLeadingInsetFromSidebarEnd: CGFloat = 41
    private static let gapBeforeHelp: CGFloat = 24
    private static let panelInset: CGFloat = 2

    static func frame(
        in codexWindow: CGRect,
        panelSize: CGSize,
        shadowMargin: CGFloat,
        helpLeadingX: CGFloat?,
        manualPosition: CodexOverlayRelativePosition?
    ) -> CGRect {
        if let manualPosition {
            return frame(
                in: codexWindow,
                panelSize: panelSize,
                manualPosition: manualPosition
            )
        }

        let fallbackHelpX = codexWindow.minX
            + min(sidebarWidth, codexWindow.width)
            - helpLeadingInsetFromSidebarEnd
        let anchorX: CGFloat
        if let helpLeadingX,
           helpLeadingX.isFinite,
           codexWindow.minX...codexWindow.maxX ~= helpLeadingX {
            anchorX = helpLeadingX
        } else {
            anchorX = fallbackHelpX
        }

        let contentWidth = max(1, panelSize.width - shadowMargin * 2)
        let proposed = CGRect(
            x: anchorX - gapBeforeHelp - contentWidth - shadowMargin,
            y: codexWindow.minY + panelInset,
            width: panelSize.width,
            height: panelSize.height
        )
        return clampedFrame(proposed, in: codexWindow)
    }

    static func clampedFrame(_ frame: CGRect, in codexWindow: CGRect) -> CGRect {
        let xRange = originRange(
            minimum: codexWindow.minX,
            maximum: codexWindow.maxX,
            itemLength: frame.width
        )
        let yRange = originRange(
            minimum: codexWindow.minY,
            maximum: codexWindow.maxY,
            itemLength: frame.height
        )
        return CGRect(
            x: min(xRange.upperBound, max(xRange.lowerBound, frame.minX)),
            y: min(yRange.upperBound, max(yRange.lowerBound, frame.minY)),
            width: frame.width,
            height: frame.height
        )
    }

    static func relativePosition(
        for frame: CGRect,
        in codexWindow: CGRect
    ) -> CodexOverlayRelativePosition {
        let clamped = clampedFrame(frame, in: codexWindow)
        let xRange = originRange(
            minimum: codexWindow.minX,
            maximum: codexWindow.maxX,
            itemLength: frame.width
        )
        let yRange = originRange(
            minimum: codexWindow.minY,
            maximum: codexWindow.maxY,
            itemLength: frame.height
        )
        return CodexOverlayRelativePosition(
            horizontal: fraction(clamped.minX, in: xRange),
            vertical: fraction(clamped.minY, in: yRange)
        )
    }

    private static func frame(
        in codexWindow: CGRect,
        panelSize: CGSize,
        manualPosition: CodexOverlayRelativePosition
    ) -> CGRect {
        let xRange = originRange(
            minimum: codexWindow.minX,
            maximum: codexWindow.maxX,
            itemLength: panelSize.width
        )
        let yRange = originRange(
            minimum: codexWindow.minY,
            maximum: codexWindow.maxY,
            itemLength: panelSize.height
        )
        return CGRect(
            x: xRange.lowerBound
                + (xRange.upperBound - xRange.lowerBound) * manualPosition.horizontal,
            y: yRange.lowerBound
                + (yRange.upperBound - yRange.lowerBound) * manualPosition.vertical,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    private static func originRange(
        minimum: CGFloat,
        maximum: CGFloat,
        itemLength: CGFloat
    ) -> ClosedRange<CGFloat> {
        let lower = minimum + panelInset
        return lower...max(lower, maximum - panelInset - itemLength)
    }

    private static func fraction(
        _ value: CGFloat,
        in range: ClosedRange<CGFloat>
    ) -> CGFloat {
        let distance = range.upperBound - range.lowerBound
        guard distance > 0 else { return 0 }
        return (value - range.lowerBound) / distance
    }
}
