import ApplicationServices
import CoreGraphics
import Foundation

struct CodexHelpAnchor: Equatable, Sendable {
    enum HorizontalOffset: Equatable, Sendable {
        case fromLeading(CGFloat)
        case fromTrailing(CGFloat)
    }

    let horizontalOffset: HorizontalOffset

    func leadingX(in appKitWindowFrame: CGRect) -> CGFloat {
        switch horizontalOffset {
        case let .fromLeading(offset):
            appKitWindowFrame.minX + offset
        case let .fromTrailing(offset):
            appKitWindowFrame.maxX - offset
        }
    }
}

enum CodexAccessibilityAnchorReader {
    private struct Control {
        let frame: CGRect
        let labels: [String]
    }

    private static let traversalLimit = 500
    private static let depthLimit = 12
    private static let sidebarWidth: CGFloat = 438
    private static let expectedBottomInset: CGFloat = 24
    private static let expectedEdgeInset: CGFloat = 24
    private static let helpWords = [
        "help", "support", "question", "questionmark", "帮助", "问号", "?"
    ]

    static func helpAnchor(
        processID: pid_t,
        matching quartzWindowFrame: CGRect
    ) -> CodexHelpAnchor? {
        guard AXIsProcessTrusted(), !isCancelled else { return nil }

        let application = AXUIElementCreateApplication(processID)
        guard let windows = copyAttribute(
            application,
            kAXWindowsAttribute as CFString
        ) as? [AXUIElement] else {
            return nil
        }

        let windowAndFrame = windows.compactMap { window -> (AXUIElement, CGRect)? in
            guard let frame = elementFrame(window) else { return nil }
            return (window, frame)
        }.max { first, second in
            intersectionArea(first.1, quartzWindowFrame)
                < intersectionArea(second.1, quartzWindowFrame)
        }
        guard let windowAndFrame,
              intersectionArea(windowAndFrame.1, quartzWindowFrame) > 0 else {
            return nil
        }

        return chooseHelpControl(
            from: controls(in: windowAndFrame.0),
            windowFrame: quartzWindowFrame
        )
    }

    private static func controls(in root: AXUIElement) -> [Control] {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        var visited: Set<CFHashCode> = []
        var result: [Control] = []

        while index < queue.count,
              visited.count < traversalLimit,
              !isCancelled {
            let item = queue[index]
            index += 1

            guard visited.insert(CFHash(item.element)).inserted else { continue }
            if let role = stringAttribute(item.element, kAXRoleAttribute as CFString),
               role == (kAXButtonRole as String)
                    || role == (kAXPopUpButtonRole as String),
               let frame = elementFrame(item.element) {
                let labels = [
                    kAXTitleAttribute,
                    kAXDescriptionAttribute,
                    kAXHelpAttribute,
                    kAXIdentifierAttribute,
                    kAXValueAttribute
                ].compactMap {
                    stringAttribute(item.element, $0 as CFString)
                }
                result.append(Control(frame: frame, labels: labels))
            }

            guard item.depth < depthLimit,
                  let children = copyAttribute(
                    item.element,
                    kAXChildrenAttribute as CFString
                  ) as? [AXUIElement] else {
                continue
            }
            queue.append(contentsOf: children.map {
                (element: $0, depth: item.depth + 1)
            })
        }
        return result
    }

    private static func chooseHelpControl(
        from controls: [Control],
        windowFrame: CGRect
    ) -> CodexHelpAnchor? {
        let expectedSidebarX = windowFrame.minX
            + min(sidebarWidth, windowFrame.width)
            - expectedEdgeInset
        let expectedTrailingX = windowFrame.maxX - expectedEdgeInset

        let matches = controls.compactMap { control -> (Control, CGFloat, Bool)? in
            let normalizedLabels = control.labels
                .joined(separator: " ")
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                .lowercased()
            guard helpWords.contains(where: { normalizedLabels.contains($0) }),
                  (12...72).contains(control.frame.width),
                  (12...72).contains(control.frame.height),
                  intersectionArea(control.frame, windowFrame)
                    >= control.frame.width * control.frame.height * 0.9 else {
                return nil
            }

            let distanceFromBottom = windowFrame.maxY - control.frame.midY
            guard (0...110).contains(distanceFromBottom) else { return nil }

            let sidebarDistance = abs(control.frame.midX - expectedSidebarX)
            let trailingDistance = abs(control.frame.midX - expectedTrailingX)
            let belongsToSidebar = sidebarDistance <= trailingDistance
            let horizontalDistance = min(sidebarDistance, trailingDistance)
            guard horizontalDistance <= 130 else { return nil }

            let score = horizontalDistance
                + abs(distanceFromBottom - expectedBottomInset)
                + (belongsToSidebar ? 0 : 18)
            return (control, score, belongsToSidebar)
        }

        guard let selected = matches.min(by: { $0.1 < $1.1 }) else {
            return nil
        }
        if selected.2 {
            return CodexHelpAnchor(horizontalOffset: .fromLeading(
                selected.0.frame.minX - windowFrame.minX
            ))
        }
        return CodexHelpAnchor(horizontalOffset: .fromTrailing(
            windowFrame.maxX - selected.0.frame.minX
        ))
    }

    private static var isCancelled: Bool {
        withUnsafeCurrentTask { task in task?.isCancelled ?? false }
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = axValueAttribute(
            element,
            kAXPositionAttribute as CFString
        ), AXValueGetType(positionValue) == .cgPoint,
        let sizeValue = axValueAttribute(
            element,
            kAXSizeAttribute as CFString
        ), AXValueGetType(sizeValue) == .cgSize else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> String? {
        copyAttribute(element, name) as? String
    }

    private static func axValueAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> AXValue? {
        guard let value = copyAttribute(element, name),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private static func copyAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let overlap = first.intersection(second)
        guard !overlap.isNull else { return 0 }
        return overlap.width * overlap.height
    }
}
