import XCTest

/// Signed out → "Sign in with Google" → Google's own sign-in page loads in the system sheet.
/// Stops there: finishing needs a real Google account, typed by a person. Needs a
/// token-mode server with COOKBOOK_GOOGLE_CLIENT_IDS set, and is skipped unless
/// SIGNIN_SHOT_DIR is set:
///
///   TEST_RUNNER_SIGNIN_SHOT_DIR=/tmp/shots TEST_RUNNER_COOKBOOK_API_URL=http://127.0.0.1:8001 \
///     xcodebuild test -scheme Screenshots -only-testing:CookbookUITests/GoogleSignInFlow …
final class GoogleSignInFlow: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let safariViewService = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
    private var app: XCUIApplication!
    private var outputDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SIGNIN_SHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set SIGNIN_SHOT_DIR and point COOKBOOK_API_URL at a token-mode server.")
        }
        outputDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        if let api = env["COOKBOOK_API_URL"] { app.launchEnvironment["COOKBOOK_API_URL"] = api }
        app.launch()
    }

    func testSignInOpensGooglesSignInPage() throws {
        let button = app.buttons["Sign in with Google"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "signed-out screen didn't appear")
        snap("1-signed-out")
        button.tap()

        // iOS asks before handing the sign-in to google.com.
        let proceed = springboard.buttons["Continue"]
        if proceed.waitForExistence(timeout: 10) {
            snap("2-system-prompt")
            proceed.tap()
        }
        // Google's page, not an "Error 400" page about the client or redirect. The sheet's
        // web content may be reported under the app or under SafariViewService.
        let pages = [app!, safariViewService]
        // Text only Google's page has (the app's own screen also says "Sign in").
        let loaded = NSPredicate(format: "label CONTAINS[c] 'Email or phone' OR label CONTAINS[c] 'Choose an account' OR label CONTAINS[c] 'Forgot email'")
        let found = waitForAny(pages.map { $0.descendants(matching: .any).matching(loaded).firstMatch }, timeout: 30)
        snap(found ? "3-google-page" : "3-FAILED-google-page")
        XCTAssertTrue(found, "Google's sign-in page didn't load")
        let rejected = NSPredicate(format: "label CONTAINS[c] 'Error 400' OR label CONTAINS[c] 'invalid_request'")
        XCTAssertFalse(pages.contains { $0.descendants(matching: .any).matching(rejected).firstMatch.exists }, "Google rejected the request")
    }

    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: \.exists) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    private func snap(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }
}
