import XCTest

/// Permission-free smoke test. It opens no feeds, media, or model connections.
final class NavigationTests: XCTestCase {
    func testLibrarySnipsAndSettingsOpenWithoutPermissions() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["PodSnip"].waitForExistence(timeout: 10))
        app.tabBars.buttons["擷取"].tap()
        XCTAssertTrue(app.navigationBars["我的擷取"].waitForExistence(timeout: 5))
        app.tabBars.buttons["設定"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["AI 來源"].exists)
        app.terminate()
    }
}
