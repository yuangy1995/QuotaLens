import AppKit
import XCTest
@testable import QuotaLens

final class ToolAppIconTests: XCTestCase {
    @MainActor
    func testClaudeFallbackIsAvailableWithoutInstalledApplication() throws {
        let image = try XCTUnwrap(ToolAppIcon.fallbackImage(for: .claude))
        XCTAssertEqual(image.size, NSSize(width: 128, height: 128))
        XCTAssertFalse(image.isTemplate)
        XCTAssertNotNil(image.tiffRepresentation)
        if let output = ProcessInfo.processInfo.environment["QUOTALENS_CAPACITY_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("claude-fallback.png"))
        }
    }

    @MainActor
    func testOtherToolsKeepExistingFallbackBehavior() {
        XCTAssertNil(ToolAppIcon.fallbackImage(for: .codex))
        XCTAssertNil(ToolAppIcon.fallbackImage(for: .antigravity))
    }
}
