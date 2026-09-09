import CoreGraphics
import XCTest
@testable import QuotaLens

final class CodexOverlayPositioningTests: XCTestCase {
    private let main = CodexOverlayWindow(
        windowID: 1, processID: 100, layer: 0, alpha: 1,
        quartzFrame: CGRect(x: 100, y: 100, width: 1400, height: 1000)
    )
    private let popup = CodexOverlayWindow(
        windowID: 2, processID: 100, layer: 0, alpha: 1,
        quartzFrame: CGRect(x: 850, y: 350, width: 600, height: 400),
        title: "Computer Use"
    )

    func testPopupDoesNotReplaceTrackedMainWindow() {
        XCTAssertEqual(select([popup, main], previous: main.windowID), main)
    }

    func testStartupWithPopupSelectsMainWindow() {
        XCTAssertEqual(select([popup, main]), main)
    }

    func testRecoversFromPreviouslySelectedPopup() {
        XCTAssertEqual(select([popup, main], previous: popup.windowID), main)
    }

    func testPopupOpeningAndClosingKeepsOverlayFrame() throws {
        let display = CodexOverlayDisplay(
            quartzFrame: CGRect(x: 0, y: 0, width: 2000, height: 1400),
            appKitFrame: CGRect(x: 0, y: 0, width: 2000, height: 1400)
        )
        let anchor = CodexHelpAnchor(horizontalOffset: .fromLeading(397))
        var previous: CGWindowID?
        var frames: [CGRect] = []
        for windows in [[main], [popup, main], [main]] {
            let target = try XCTUnwrap(select(windows, previous: previous))
            previous = target.windowID
            let frame = try XCTUnwrap(CodexOverlayWindowLocator.appKitFrame(
                from: target.quartzFrame, displays: [display]
            ))
            frames.append(CodexOverlayLayout.frame(
                in: frame,
                panelSize: CGSize(width: 182, height: 54),
                shadowMargin: 10,
                helpLeadingX: anchor.leadingX(in: frame),
                manualPosition: nil
            ))
        }
        XCTAssertEqual(frames[0], frames[1])
        XCTAssertEqual(frames[1], frames[2])
    }

    func testCanStillSwitchToAnotherIndependentWindow() {
        let other = CodexOverlayWindow(
            windowID: 3, processID: 100, layer: 0, alpha: 1,
            quartzFrame: CGRect(x: 1100, y: 200, width: 900, height: 800)
        )
        XCTAssertEqual(select([other, main], previous: main.windowID), other)
    }

    func testSameSizedWindowsRemainSelectable() {
        let other = CodexOverlayWindow(
            windowID: 3, processID: 100, layer: 0, alpha: 1,
            quartzFrame: main.quartzFrame
        )
        XCTAssertEqual(select([other, main], previous: main.windowID), other)
    }

    func testOtherApplicationCannotDisqualifyWindow() {
        let other = CodexOverlayWindow(
            windowID: 3, processID: 200, layer: 0, alpha: 1,
            quartzFrame: CGRect(x: 0, y: 0, width: 2000, height: 1400)
        )
        XCTAssertEqual(select([other, main]), main)
    }

    func testNoEligibleWindowReturnsNil() {
        XCTAssertNil(select([]))
    }

    func testActualPictureInPictureWindowsExtendingBeyondMainAreExcluded() {
        let main = CodexOverlayWindow(
            windowID: 16343, processID: 100, layer: 0, alpha: 1,
            quartzFrame: CGRect(x: 0, y: 30, width: 2048, height: 1036),
            title: "ChatGPT"
        )
        let picture = CodexOverlayWindow(
            windowID: 16640, processID: 100, layer: 0, alpha: 1,
            quartzFrame: CGRect(x: 1558, y: 496, width: 532, height: 300),
            title: "Computer Use"
        )
        let controls = CodexOverlayWindow(
            windowID: 16641, processID: 100, layer: 0, alpha: 1,
            quartzFrame: picture.quartzFrame, title: "Computer Use Controls"
        )
        XCTAssertEqual(select([controls, picture, main]), main)
        XCTAssertEqual(select([controls, picture, main], previous: picture.windowID), main)
        XCTAssertNil(select([controls, picture]))

        let anonymousWindows = [controls, picture, main].map { window in
            var window = window
            window.title = nil
            return window
        }
        XCTAssertEqual(select(anonymousWindows), anonymousWindows.last)
        XCTAssertEqual(
            select(anonymousWindows, previous: picture.windowID), anonymousWindows.last
        )
    }

    func testSmallerRealWindowInsideMainRemainsSelectable() {
        let other = CodexOverlayWindow(
            windowID: 3, processID: 100, layer: 0, alpha: 1,
            quartzFrame: popup.quartzFrame, title: "Another task"
        )
        XCTAssertEqual(select([other, main], previous: main.windowID), other)
    }

    func testOtherOverlayCallersKeepExistingSelectionBehavior() {
        XCTAssertEqual(CodexOverlayWindowLocator.selectWindow(
            processIDs: [100], focusedProcessID: 100,
            previousWindowID: main.windowID, windows: [popup, main]
        ), popup)
    }

    private func select(
        _ windows: [CodexOverlayWindow],
        previous: CGWindowID? = nil
    ) -> CodexOverlayWindow? {
        CodexOverlayWindowLocator.selectWindow(
            processIDs: [100, 200], focusedProcessID: 100,
            previousWindowID: previous, windows: windows,
            excludingComputerUseWindows: true
        )
    }
}
