import XCTest

/// Drives Safari → Share → Cookbook and checks the app opens on the import for that link.
/// Stops at the app's "Import from Instagram?" confirmation, so the app never loads
/// Instagram. (Safari itself loads the page being shared.) Skipped unless SHARE_SHOT_DIR
/// is set:
///
///   TEST_RUNNER_SHARE_SHOT_DIR=/tmp/shots TEST_RUNNER_COOKBOOK_API_URL=http://127.0.0.1:8101 \
///     xcodebuild test -scheme Screenshots -only-testing:CookbookUITests/ShareExtensionFlow …
final class ShareExtensionFlow: XCTestCase {
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var app: XCUIApplication!
    private var outputDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SHARE_SHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set SHARE_SHOT_DIR to drive the share extension from Safari.")
        }
        outputDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        if let api = env["COOKBOOK_API_URL"] { app.launchEnvironment["COOKBOOK_API_URL"] = api }
        // Launch once so the app is installed and registered, then leave it in the background.
        app.launch()
        XCUIDevice.shared.press(.home)
    }

    func testSharingAnInstagramReelOpensTheImport() throws {
        share("https://www.instagram.com/reel/DF7v5Fxx5Ot/?igsh=abc123", prefix: "reel")
        allowOpeningIfAsked()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "Cookbook didn't come to the front")
        let alert = app.alerts["Import from Instagram?"]
        if !alert.waitForExistence(timeout: 15) { snap("reel-FAILED-no-alert"); XCTFail("no import confirmation") }
        XCTAssertTrue(alert.staticTexts["https://www.instagram.com/reel/DF7v5Fxx5Ot/"].exists,
                      "confirmation shows the canonical link")
        snap("reel-4-app-import-confirmation")
    }

    func testSharingAnotherLinkExplainsAndStaysPut() throws {
        share("https://example.com/recipes/garlic-noodles", prefix: "other")
        let message = safari.staticTexts["Not an Instagram post"]
        if !message.waitForExistence(timeout: 15) { snap("other-FAILED-no-message"); XCTFail("no message") }
        snap("other-3-extension-not-instagram")
        XCTAssertNotEqual(app.state, .runningForeground, "the app must not open")
        safari.buttons["Done"].tap()
    }

    // MARK: Helpers

    /// Opens `link` in Safari, taps Share, then Cookbook in the share sheet.
    private func share(_ link: String, prefix: String) {
        XCUIDevice.shared.system.open(URL(string: link)!)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "Safari didn't open")
        Thread.sleep(forTimeInterval: 3)
        snap("\(prefix)-1-safari")

        tapShare()
        let cookbook = safari.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Cookbook' AND (elementType == %d OR elementType == %d)",
                                  XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue))
            .firstMatch
        if !cookbook.waitForExistence(timeout: 10) {
            snap("\(prefix)-FAILED-no-cookbook-in-share-sheet")
            XCTFail("Cookbook isn't in the share sheet:\n\(safari.debugDescription)")
        }
        snap("\(prefix)-2-share-sheet")
        cookbook.tap()
        Thread.sleep(forTimeInterval: 1)
        snap("\(prefix)-3-after-tapping-cookbook")
    }

    /// iOS 27 Safari may keep Share behind the "…" menu.
    private func tapShare() {
        let share = safari.buttons["Share"].firstMatch
        if share.waitForExistence(timeout: 5), share.isHittable { share.tap(); return }
        for more in ["More", "Page Menu", "Show Menu", "Tab Options"] {
            let button = safari.buttons[more].firstMatch
            if button.exists && button.isHittable {
                button.tap()
                let item = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Share'")).firstMatch
                // A long menu (e.g. with Notify Me) opens scrolled past its Share row.
                let firstRow = safari.buttons["FindOnPage"].firstMatch
                for _ in 0..<3 where !(item.exists && item.isHittable) && firstRow.exists {
                    firstRow.swipeDown()
                }
                if item.waitForExistence(timeout: 5) { item.tap(); return }
            }
        }
        snap("FAILED-no-share-button")
        XCTFail("no Share button:\n\(safari.debugDescription)")
    }

    /// iOS may ask "Open in "Cookbook"?" when one app opens another.
    private func allowOpeningIfAsked() {
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 4) { snap("reel-3b-system-open-prompt"); open.tap() }
    }

    private func snap(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }
}
