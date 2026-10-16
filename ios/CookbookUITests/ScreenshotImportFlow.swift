import XCTest

/// Walks + → Import from Screenshot against a dev-mode server and saves a screenshot of each
/// step. Needs test images in the Simulator's photo library, added in this order with
/// `xcrun simctl addmedia`: a full recipe screenshot, the same caption split over two
/// overlapping screenshots, and a plain image with no text (so the newest four photos are,
/// newest first: no text, part 2, part 1, full).
///
///   TEST_RUNNER_SCREENSHOT_DIR=/tmp/shots TEST_RUNNER_COOKBOOK_UI_API_URL=http://127.0.0.1:8102 \
///     xcodebuild test -scheme Screenshots -only-testing:CookbookUITests/ScreenshotImportFlow …
final class ScreenshotImportFlow: XCTestCase {
    private var app: XCUIApplication!
    private var outputDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SCREENSHOT_DIR"], !dir.isEmpty,
              let api = env["COOKBOOK_UI_API_URL"], !api.isEmpty else {
            throw XCTSkip("Set SCREENSHOT_DIR and COOKBOOK_UI_API_URL to run the screenshot import flow.")
        }
        outputDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["COOKBOOK_API_URL"] = api
        app.launch()
    }

    private func snap(_ name: String) {
        Thread.sleep(forTimeInterval: 1.5)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    private func waitFor(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15) {
        if !element.waitForExistence(timeout: timeout) {
            snap("FAILED-\(what.replacingOccurrences(of: " ", with: "-"))")
            XCTFail("\(what) didn't appear")
        }
    }

    private var caption: String { app.textViews["Caption"].value as? String ?? "" }

    /// The photo picker's grid cells, newest first.
    private func pickerPhotos() -> [XCUIElement] {
        let photos = app.images.matching(NSPredicate(format: "label CONTAINS[c] 'photo'"))
        waitFor(photos.firstMatch, "photo picker")
        Thread.sleep(forTimeInterval: 1)
        let all = photos.allElementsBoundByIndex
        print("Picker photos: \(all.map(\.label))")
        return all
    }

    /// Taps the picker's confirm button (multi-select pickers need one).
    private func confirmPicker() {
        for label in ["Add", "Done"] {
            let button = app.buttons[label].firstMatch
            if button.waitForExistence(timeout: 3) { button.tap(); return }
        }
        let buttons = app.buttons.allElementsBoundByIndex.map(\.label)
        XCTFail("no Add/Done button in the picker; buttons: \(buttons)")
    }

    /// The button sits under the caption, which can be long: scroll to it first.
    private func tapReadTextButton() {
        let button = app.buttons["Read Text from Screenshots"]
        for _ in 0..<8 where !(button.exists && button.isHittable) {
            app.swipeUp()
        }
        button.tap()
    }

    /// The picker's ✕. Over the list it's a "Cancel" button; over the Import Caption sheet
    /// it isn't in the accessibility tree, so tap where it is drawn (top left of the picker).
    private func cancelPicker() {
        if app.navigationBars["Import Caption"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.094, dy: 0.165)).tap()
        } else {
            app.buttons["Cancel"].firstMatch.tap()
        }
    }

    func testImportFromScreenshots() throws {
        // + → Import from Screenshot opens the picker; cancelling it opens nothing.
        app.navigationBars.buttons["Add Recipe"].tap()
        snap("ocr-01-add-menu")
        app.buttons["Import from Screenshot"].tap()
        var photos = pickerPhotos()
        XCTAssertGreaterThanOrEqual(photos.count, 4, "the test images are in the library")
        snap("ocr-02-picker")
        cancelPicker()
        waitFor(app.navigationBars["Cookbook"], "list after cancel")
        XCTAssertFalse(app.navigationBars["Import Caption"].exists, "cancel opens nothing")

        // Two overlapping screenshots, picked in order.
        app.navigationBars.buttons["Add Recipe"].tap()
        app.buttons["Import from Screenshot"].tap()
        photos = pickerPhotos()
        photos[2].tap()  // first part
        photos[1].tap()  // second part
        snap("ocr-03-picker-two-selected")
        confirmPicker()

        waitFor(app.navigationBars["Import Caption"], "import caption")
        waitFor(app.staticTexts["Text from 2 screenshots was added to the caption."], "added notice", timeout: 30)
        snap("ocr-04-two-screenshots-added")
        let text = caption
        print("Caption after two screenshots:\n\(text)")
        XCTAssertTrue(text.hasPrefix("maple_test_kitchen"), "first screenshot first")
        XCTAssertTrue(text.contains("Ingredients"))
        XCTAssertTrue(text.contains("2 tbsp sugar"))
        XCTAssertTrue(text.contains("3. Cook 1/4 cup scoops for 2 minutes a side."))
        XCTAssertEqual(text.components(separatedBy: "3/4 cup ricotta").count - 1, 1,
                       "the overlap between the screenshots appears once")
        if text.contains("11/2") {
            // The Simulator's Vision drops the space in "1 1/2"; the screen must point it out.
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Check 11/2'")).firstMatch.exists)
        }
        XCTAssertTrue(app.navigationBars.buttons["Read Recipe"].isEnabled, "nothing auto-submits")
        XCTAssertFalse(app.navigationBars["Review Recipe"].exists)

        // A screenshot with no text, from the button on this screen: the caption is unchanged.
        tapReadTextButton()
        photos = pickerPhotos()
        photos[0].tap()
        confirmPicker()
        waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No text was found'")).firstMatch,
                "no-text notice", timeout: 30)
        snap("ocr-05-no-text")
        XCTAssertEqual(caption, text, "no text found leaves the caption as it was")

        // Cancelling the picker from the button also leaves it alone.
        tapReadTextButton()
        _ = pickerPhotos()
        cancelPicker()
        waitFor(app.navigationBars["Import Caption"], "import caption after cancel")
        XCTAssertEqual(caption, text, "cancel leaves the caption as it was")
        app.navigationBars["Import Caption"].buttons["Cancel"].tap()

        // The full screenshot, then Read Recipe → review.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.navigationBars["Import Caption"])
        if XCTWaiter.wait(for: [gone], timeout: 10) != .completed {
            snap("FAILED-sheet-still-open")
            print("Buttons: \(app.buttons.allElementsBoundByIndex.map(\.label))")
            XCTFail("Import Caption didn't close")
        }
        waitFor(app.navigationBars["Cookbook"], "list")
        app.navigationBars.buttons["Add Recipe"].tap()
        app.buttons["Import from Screenshot"].tap()
        photos = pickerPhotos()
        photos[3].tap()
        confirmPicker()
        waitFor(app.staticTexts["Text from a screenshot was added to the caption."], "single added notice", timeout: 30)
        snap("ocr-06-one-screenshot-added")
        print("Caption from the full screenshot:\n\(caption)")
        XCTAssertTrue(caption.contains("Lemon Ricotta Pancakes"))
        XCTAssertTrue(caption.contains("Steps"))

        app.navigationBars.buttons["Read Recipe"].tap()
        waitFor(app.navigationBars["Review Recipe"], "review screen", timeout: 60)
        snap("ocr-07-review")
        app.swipeUp()
        snap("ocr-08-review-scrolled")
        app.swipeUp()
        snap("ocr-09-review-bottom")
    }
}
