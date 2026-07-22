import XCTest

final class ScaffoldUITests: XCTestCase {
    @MainActor
    func testEmptyShellIsAccessibleAndViewerFocused() {
        let app = XCUIApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["emptyState"].exists)
        XCTAssertTrue(app.buttons["empty.openButton"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["statusBar"].exists)
        XCTAssertEqual(app.toolbars.count, 0)
        XCTAssertEqual(app.outlines.count, 0)
    }
}
