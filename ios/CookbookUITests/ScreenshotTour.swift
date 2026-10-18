import XCTest

/// Walks the main screens against the live server and saves a screenshot of each, for UI
/// reviews and before/after comparisons. Not a correctness test: it only fails if a screen
/// can't be reached. Run with ios/screenshots.sh (needs the backend running and the
/// Simulator app paired or pointed at a dev-mode server).
final class ScreenshotTour: XCTestCase {
    private var app: XCUIApplication!
    private var outputDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set SCREENSHOT_DIR (ios/screenshots.sh does) to take screenshots.")
        }
        outputDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launch()
    }

    private func snap(_ name: String) {
        // Let images and animations settle.
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

    /// iOS 27 draws some Cancel buttons as an ✕ labelled "Close".
    private func tapFirst(_ labels: [String], _ what: String) {
        for _ in 0..<10 {
            for label in labels {
                let button = app.buttons[label].firstMatch
                if button.exists && button.isHittable { button.tap(); return }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let onScreen = app.buttons.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" }
        XCTFail("no \(what) button (\(labels)); buttons: \(onScreen)")
    }

    /// A recipe card (or any element) whose accessibility label starts with `title`.
    private func recipe(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func openAddMenu() {
        app.navigationBars.buttons["Add Recipe"].tap()
    }

    private func cancelSheet() {
        tapFirst(["Cancel", "Close", "close"], "cancel")
        // Editors ask before discarding typing.
        let discard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Discard'")).firstMatch
        if discard.waitForExistence(timeout: 1) { discard.tap() }
    }

    func testTour() throws {
        // List
        waitFor(recipe("Honey buffalo crispy chicken"), "recipe list")
        snap("01-list")

        // Search
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("chicken")
        snap("02-search")
        search.typeText("zzz")
        snap("03-search-empty")
        tapFirst(["Cancel", "Close", "close"], "search cancel")

        // Add menu
        openAddMenu()
        snap("04-add-menu")
        app.buttons["Import from Instagram Link"].tap()
        snap("05-instagram-link-prompt")
        app.alerts.buttons["Cancel"].tap()

        // Recipe with a photo and many ingredients
        recipe("High Protein Grilled Cheese Breakfast Burritos").tap()
        waitFor(app.staticTexts["Ingredients"], "recipe detail")
        snap("06-detail-top")
        app.swipeUp()
        snap("07-detail-scrolled")
        app.swipeUp()
        snap("08-detail-bottom")

        // Editor
        app.navigationBars.buttons["Edit"].tap()
        waitFor(app.navigationBars["Edit Recipe"], "editor")
        snap("09-editor")
        app.swipeUp()
        snap("10-editor-scrolled")
        cancelSheet()
        app.navigationBars.buttons.element(boundBy: 0).tap()  // back

        // Imported recipe without a photo
        waitFor(recipe("Honey buffalo crispy chicken"), "list again")
        recipe("Honey buffalo crispy chicken").tap()
        waitFor(app.staticTexts["Ingredients"], "second recipe")
        snap("11-detail-no-photo")
        app.navigationBars.buttons["More"].tap()
        snap("11b-more-menu")
        app.tap()  // dismiss the menu
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Photo round trip on the test recipe: add from the library, then delete it again.
        // At large text sizes the grid is one column and the card may be off-screen.
        for _ in 0..<6 where !recipe("QA Lemon Chicken").isHittable { app.swipeUp() }
        waitFor(recipe("QA Lemon Chicken"), "QA recipe")
        recipe("QA Lemon Chicken").tap()
        waitFor(app.buttons["Add Photo"], "add-photo placeholder")
        app.buttons["Add Photo"].tap()
        let libraryPhoto = app.images.matching(NSPredicate(format: "label CONTAINS[c] 'photo'")).firstMatch
        waitFor(libraryPhoto, "photo picker")
        libraryPhoto.tap()
        waitFor(app.images["Recipe photo"], "uploaded photo", timeout: 30)
        snap("11c-detail-photo-added")
        app.navigationBars.buttons["More"].tap()
        app.buttons["Delete This Photo"].tap()
        app.buttons["Delete Photo"].firstMatch.tap()
        waitFor(app.buttons["Add Photo"], "placeholder after delete", timeout: 20)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // New recipe (empty editor)
        openAddMenu()
        app.buttons["New Recipe"].tap()
        waitFor(app.navigationBars["New Recipe"], "new recipe")
        snap("12-new-recipe")
        cancelSheet()

        // Import caption: empty, then reading (local model), then review
        openAddMenu()
        app.buttons["Import Caption"].tap()
        waitFor(app.navigationBars["Import Caption"], "import caption")
        snap("13-import-empty")
        let editor = app.textViews.firstMatch
        editor.tap()
        editor.typeText("""
        Lemon garlic orzo 🍋
        Ingredients:
        - 1 cup orzo
        - 2 cloves garlic
        - 1 lemon, zested
        - salt to taste
        1. Toast the orzo in butter.
        2. Add stock and simmer 10 minutes.
        3. Stir in garlic and lemon zest.
        #dinner
        """)
        // Stop keeps the caption and lets the user try again.
        app.navigationBars.buttons["Read Recipe"].tap()
        waitFor(app.navigationBars.buttons["Stop"], "Stop button")
        app.navigationBars.buttons["Stop"].tap()
        waitFor(app.navigationBars.buttons["Cancel"], "Cancel after Stop")
        XCTAssertTrue(app.navigationBars.buttons["Read Recipe"].isEnabled, "can read again after Stop")
        XCTAssertTrue((app.textViews.firstMatch.value as? String)?.contains("Lemon garlic orzo") == true, "caption kept")

        app.navigationBars.buttons["Read Recipe"].tap()
        Thread.sleep(forTimeInterval: 3)
        snap("14-import-reading")
        waitFor(app.navigationBars["Review Recipe"], "review screen", timeout: 150)
        snap("15-review")
        app.swipeUp()
        snap("16-review-scrolled")
        cancelSheet()

        // Settings
        app.navigationBars.buttons["Settings"].tap()
        snap("17-settings")
        app.buttons["Sign In Again or Use a New Code"].tap()
        snap("18-settings-pairing")
    }
}
