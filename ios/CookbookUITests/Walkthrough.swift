import XCTest

/// Taps through the Milestone 1–3 flows against a throwaway dev-mode server and saves a
/// screenshot of each key state. Unlike ScreenshotTour, this one asserts what it sees.
/// It deletes every recipe on the server it is pointed at, so never point it at real data.
///
///   TEST_RUNNER_WALKTHROUGH_DIR=/tmp/shots \
///   TEST_RUNNER_WALKTHROUGH_API_URL=http://127.0.0.1:8103 \
///   TEST_RUNNER_WALKTHROUGH_FAILING_API_URL=http://127.0.0.1:8104 \
///   xcodebuild test -scheme Screenshots -only-testing:CookbookUITests/Walkthrough ...
///
/// The failing URL is a server whose extraction provider can't be reached (for the
/// "Enter Manually Instead" path); that test skips without it.
final class Walkthrough: XCTestCase {
    private var app: XCUIApplication!
    private var outputDir: URL!
    private var apiURL: URL!

    private static let duplicateLink = "https://www.instagram.com/reel/WALKdup123/"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["WALKTHROUGH_DIR"], !dir.isEmpty,
              let api = env["WALKTHROUGH_API_URL"], let url = URL(string: api) else {
            throw XCTSkip("Set WALKTHROUGH_DIR and WALKTHROUGH_API_URL (a throwaway dev-mode server).")
        }
        outputDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        apiURL = url
    }

    private func launch(api: URL) {
        app = XCUIApplication()
        // The argument domain beats a saved pairing, so the app talks to this server.
        app.launchArguments = ["-serverURL", api.absoluteString]
        app.launchEnvironment["COOKBOOK_API_URL"] = api.absoluteString
        app.launch()
    }

    // MARK: Helpers

    private func snap(_ name: String) {
        Thread.sleep(forTimeInterval: 1.0)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    private func waitFor(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) {
        if !element.waitForExistence(timeout: timeout) {
            snap("FAILED-\(what.replacingOccurrences(of: " ", with: "-"))")
            XCTFail("\(what) didn't appear", file: file, line: line)
        }
    }

    private func waitGone(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10,
                          file: StaticString = #filePath, line: UInt = #line) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        if XCTWaiter().wait(for: [gone], timeout: timeout) != .completed {
            snap("FAILED-still-there-\(what.replacingOccurrences(of: " ", with: "-"))")
            XCTFail("\(what) is still there", file: file, line: line)
        }
    }

    private func recipe(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// A text field or multi-line field by accessibility label, `index`-th match.
    private func field(_ label: String, _ index: Int = 0) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)", label,
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue))
            .element(boundBy: index)
    }

    private func titleField() -> XCUIElement { app.textFields.firstMatch }

    /// Clears a field and types `text`. A tap can land mid-text in a multi-line field, so
    /// it taps the end and deletes until the field is empty.
    private func replaceText(_ element: XCUIElement, with text: String) {
        element.tap()
        for _ in 0..<6 {
            let current = (element.value as? String) ?? ""
            if current.isEmpty || current == element.placeholderValue { break }
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        element.typeText(text)
    }

    /// Scrolls until `element` is on screen (Form rows off screen may not exist at all).
    private func scrollTo(_ element: XCUIElement, up: Bool) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            up ? app.swipeUp() : app.swipeDown()
        }
    }

    private func tapFirst(_ labels: [String], _ what: String) {
        for _ in 0..<10 {
            for label in labels {
                let button = app.buttons[label].firstMatch
                if button.exists && button.isHittable { button.tap(); return }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("no \(what) button (\(labels))")
    }

    private func openAdd(_ item: String) {
        app.navigationBars.buttons["Add Recipe"].tap()
        waitFor(app.buttons[item], "\(item) menu item", timeout: 5)
        app.buttons[item].tap()
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    // MARK: API (setup and the "other device" edits)

    @discardableResult
    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> (Int, Any?) {
        var request = URLRequest(url: apiURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        var result: (Int, Any?) = (0, nil)
        let done = expectation(description: "\(method) \(path)")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            result = (status, json)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        return result
    }

    private func resetRecipes() {
        while true {
            let (_, json) = call("GET", "v1/recipes", nil)
            let items = ((json as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            if items.isEmpty { return }
            for item in items { call("DELETE", "v1/recipes/\(item["id"] as! String)") }
        }
    }

    @discardableResult
    private func seed(_ title: String, ingredients: [String], steps: [String], source: String? = nil) -> String {
        var body: [String: Any] = [
            "title": title,
            "ingredients": ingredients.map { ["name": $0] },
            "steps": steps.map { ["instruction": $0] },
        ]
        if let source { body["source_url"] = source }
        let (status, json) = call("POST", "v1/recipes", body)
        XCTAssertEqual(status, 201, "seed \(title)")
        return ((json as? [String: Any])?["id"] as? String) ?? ""
    }

    private func recipeJSON(_ id: String) -> [String: Any] {
        (call("GET", "v1/recipes/\(id)").1 as? [String: Any]) ?? [:]
    }

    private func recipeID(titled title: String) -> String? {
        let (_, json) = call("GET", "v1/recipes", nil)
        let items = ((json as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.first { ($0["title"] as? String) == title }?["id"] as? String
    }

    /// Another device edits the recipe while the editor is open.
    private func editElsewhere(_ id: String, title: String) {
        let version = recipeJSON(id)["version"] as? Int ?? 0
        let (status, _) = call("PATCH", "v1/recipes/\(id)", ["version": version, "title": title])
        XCTAssertEqual(status, 200, "PATCH from 'another device'")
    }

    // MARK: Milestone 1: create, edit, stale edit, delete

    func test1CreateEditStaleDelete() throws {
        resetRecipes()
        launch(api: apiURL)
        waitFor(app.staticTexts["No Recipes Yet"], "empty list")
        snap("m1-01-empty-list")

        // Create
        openAdd("New Recipe")
        waitFor(app.navigationBars["New Recipe"], "new recipe editor")
        titleField().tap()
        titleField().typeText("Walkthrough lentil soup")
        field("Quantity").tap(); field("Quantity").typeText("1 1/2")
        field("Unit").tap(); field("Unit").typeText("cups")
        field("Ingredient name").tap(); field("Ingredient name").typeText("red lentils")
        app.buttons["Add Ingredient"].tap()
        field("Ingredient name", 1).tap(); field("Ingredient name", 1).typeText("salt to taste")
        field("Step 1").tap(); field("Step 1").typeText("Simmer the lentils for 20 minutes.")
        snap("m1-02-create-filled")
        app.navigationBars.buttons["Save"].tap()
        waitFor(recipe("Walkthrough lentil soup"), "created recipe card")
        snap("m1-03-created-in-list")
        let id = try XCTUnwrap(recipeID(titled: "Walkthrough lentil soup"))
        let created = recipeJSON(id)
        let rows = created["ingredients"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?["raw_text"] as? String, "1 1/2 cups red lentils")
        XCTAssertTrue(rows.last?["quantity"] is NSNull, "salt keeps a null quantity")

        // Detail, then edit
        recipe("Walkthrough lentil soup").tap()
        waitFor(app.staticTexts["Ingredients"], "recipe detail")
        snap("m1-04-detail")
        app.navigationBars.buttons["Edit"].tap()
        waitFor(app.navigationBars["Edit Recipe"], "editor")
        replaceText(titleField(), with: "Lentil soup")
        snap("m1-05-edit")
        app.navigationBars.buttons["Save"].tap()
        waitGone(app.navigationBars["Edit Recipe"], "editor after save")
        waitFor(app.staticTexts["Lentil soup"], "edited title on detail")
        snap("m1-06-edited-detail")
        XCTAssertEqual(recipeJSON(id)["title"] as? String, "Lentil soup")

        // Stale edit → Save My Version
        app.navigationBars.buttons["Edit"].tap()
        waitFor(app.navigationBars["Edit Recipe"], "editor (stale 1)")
        replaceText(titleField(), with: "Lentil soup, my version")
        editElsewhere(id, title: "Lentil soup from the iPad")
        app.navigationBars.buttons["Save"].tap()
        waitFor(app.alerts["This recipe changed somewhere else"], "stale-version alert")
        snap("m1-07-stale-alert")
        app.alerts.buttons["Keep Editing"].tap()
        XCTAssertEqual(titleField().value as? String, "Lentil soup, my version", "edits kept after the 409")
        snap("m1-08-stale-keep-editing")
        app.navigationBars.buttons["Save"].tap()
        waitFor(app.alerts["This recipe changed somewhere else"], "stale-version alert again")
        app.alerts.buttons["Save My Version"].tap()
        waitGone(app.navigationBars["Edit Recipe"], "editor after Save My Version")
        waitFor(app.staticTexts["Lentil soup, my version"], "my version on detail")
        snap("m1-09-saved-my-version")
        XCTAssertEqual(recipeJSON(id)["title"] as? String, "Lentil soup, my version")

        // Stale edit → Discard Mine and Reload
        app.navigationBars.buttons["Edit"].tap()
        waitFor(app.navigationBars["Edit Recipe"], "editor (stale 2)")
        replaceText(titleField(), with: "Edit to throw away")
        editElsewhere(id, title: "Lentil soup, newest")
        app.navigationBars.buttons["Save"].tap()
        waitFor(app.alerts["This recipe changed somewhere else"], "stale-version alert (discard)")
        app.alerts.buttons["Discard Mine and Reload"].tap()
        let reloaded = NSPredicate(format: "value == %@", "Lentil soup, newest")
        let reload = expectation(for: reloaded, evaluatedWith: titleField())
        XCTAssertEqual(XCTWaiter().wait(for: [reload], timeout: 10), .completed, "editor shows the newer version")
        snap("m1-10-discarded-and-reloaded")
        XCTAssertFalse(app.navigationBars.buttons["Save"].isEnabled, "nothing to save after reload")
        tapFirst(["Cancel", "Close", "close"], "cancel")
        waitFor(app.staticTexts["Lentil soup, newest"], "newest title on detail")
        snap("m1-11-detail-after-reload")

        // Delete from the detail screen
        app.navigationBars.buttons["More"].tap()
        app.buttons["Delete Recipe"].firstMatch.tap()
        waitFor(app.staticTexts["Delete this recipe?"], "delete confirmation")
        snap("m1-12-delete-confirm")
        app.buttons["Delete Recipe"].firstMatch.tap()
        waitFor(app.staticTexts["No Recipes Yet"], "empty list after delete")
        snap("m1-13-deleted")
        XCTAssertEqual(call("GET", "v1/recipes/\(id)").0, 404)

        // Delete from the list (long-press menu)
        seed("Delete me from the list", ingredients: ["bread"], steps: ["Toast it."])
        // Pull to refresh on the empty state (a recipe added from another device).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        if !recipe("Delete me from the list").waitForExistence(timeout: 5) {
            snap("m1-14a-empty-state-pull-did-not-refresh")
            print("FINDING: pull to refresh on the empty list did not load the new recipe")
            app.terminate()
            launch(api: apiURL)
        }
        waitFor(recipe("Delete me from the list"), "seeded card")
        recipe("Delete me from the list").press(forDuration: 1.2)
        waitFor(app.buttons["Delete"], "context menu")
        snap("m1-14-list-context-menu")
        app.buttons["Delete"].tap()
        waitFor(app.buttons["Delete Recipe"], "list delete confirmation")
        app.buttons["Delete Recipe"].tap()
        waitFor(app.staticTexts["No Recipes Yet"], "empty list after list delete")
        snap("m1-15-list-deleted")
    }

    // MARK: Milestone 2: search, duplicate alert, Open Existing

    func test2SearchAndDuplicates() throws {
        resetRecipes()
        seed("Tomato pasta", ingredients: ["pasta", "tomatoes", "olive oil"], steps: ["Cook pasta."])
        seed("Lemon tart", ingredients: ["lemons", "sugar", "butter"], steps: ["Bake."])
        let existing = seed("Garlic noodles", ingredients: ["noodles", "garlic"], steps: ["Fry garlic."],
                            source: Self.duplicateLink)
        launch(api: apiURL)
        waitFor(recipe("Garlic noodles"), "list")
        snap("m2-01-list")

        // Title search
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("tart")
        waitGone(recipe("Tomato pasta"), "non-matching recipe (title search)")
        XCTAssertTrue(recipe("Lemon tart").exists)
        XCTAssertFalse(recipe("Garlic noodles").exists)
        snap("m2-02-search-title")

        // Ingredient-only search: "olive" is in no title
        replaceText(search, with: "OLIVE")
        waitFor(recipe("Tomato pasta"), "ingredient match")
        waitGone(recipe("Lemon tart"), "non-matching recipe (ingredient search)")
        snap("m2-03-search-ingredient")

        replaceText(search, with: "zzzz")
        waitFor(text(containing: "No Results"), "empty search state")
        snap("m2-04-search-empty")
        tapFirst(["Cancel", "Close", "close"], "search cancel")
        waitFor(recipe("Lemon tart"), "full list after cancel")

        // Duplicate: Keep Editing, then Save Anyway
        openAdd("New Recipe")
        waitFor(app.navigationBars["New Recipe"], "new recipe editor")
        titleField().tap(); titleField().typeText("Garlic noodles again")
        field("Ingredient name").tap(); field("Ingredient name").typeText("noodles")
        field("Step 1").tap(); field("Step 1").typeText("Boil.")
        field("Instagram link").tap(); field("Instagram link").typeText(Self.duplicateLink)
        app.navigationBars.buttons["Save"].tap()
        waitFor(app.alerts["Already in your cookbook"], "duplicate alert")
        snap("m2-05-duplicate-alert")
        let alert = app.alerts["Already in your cookbook"]
        XCTAssertTrue(alert.buttons["Open Existing"].exists)
        XCTAssertTrue(alert.buttons["Save Anyway"].exists)
        XCTAssertTrue(text(containing: "Garlic noodles\u{201D}").exists, "alert names the existing recipe")
        alert.buttons["Keep Editing"].tap()
        XCTAssertEqual(titleField().value as? String, "Garlic noodles again", "form kept")
        snap("m2-06-duplicate-keep-editing")
        app.navigationBars.buttons["Save"].tap()
        waitFor(app.alerts["Already in your cookbook"], "duplicate alert again")
        app.alerts.buttons["Save Anyway"].tap()
        waitFor(recipe("Garlic noodles again"), "deliberate copy in list")
        snap("m2-07-saved-anyway")

        // Duplicate: Open Existing
        openAdd("New Recipe")
        waitFor(app.navigationBars["New Recipe"], "new recipe editor (2)")
        titleField().tap(); titleField().typeText("Third garlic noodles")
        field("Instagram link").tap(); field("Instagram link").typeText("instagram.com/reel/WALKdup123")
        app.navigationBars.buttons["Save"].tap()
        waitFor(app.alerts["Already in your cookbook"], "duplicate alert (open existing)")
        app.alerts.buttons["Open Existing"].tap()
        waitGone(app.navigationBars["New Recipe"], "editor after Open Existing")
        waitFor(app.staticTexts["Fry garlic."], "existing recipe's detail")
        XCTAssertTrue(app.staticTexts["Garlic noodles"].exists)
        snap("m2-08-open-existing")
        XCTAssertNil(recipeID(titled: "Third garlic noodles"), "nothing saved by Open Existing")
        _ = existing
    }

    // MARK: Milestone 3: Import Caption → review → save

    func test3ImportCaptionReview() throws {
        resetRecipes()
        launch(api: apiURL)
        waitFor(app.staticTexts["No Recipes Yet"], "empty list")
        openAdd("Import Caption")
        waitFor(app.navigationBars["Import Caption"], "import screen")
        // No title line before the header (→ a "Give this recipe a title" warning), and an
        // ingredient name over 200 characters (→ an orange "Shortened to fit" flag).
        let longName = "fresh basil leaves " + String(repeating: "picked from the garden ", count: 9)
        let caption = """
        Ingredients:
        - 2 cups orzo
        - ½ cup parmesan
        - salt to taste
        - \(longName)
        Method:
        1. Toast the orzo in butter.
        2. Simmer in stock for 10 minutes.
        #dinner
        """
        let editor = app.textViews["Caption"]
        editor.tap()
        editor.typeText(caption)
        snap("m3-01-caption")
        app.navigationBars.buttons["Read Recipe"].tap()
        waitFor(app.navigationBars["Review Recipe"], "review screen", timeout: 60)
        snap("m3-02-review-top")
        waitFor(text(containing: "Found 4 ingredients and 2 steps"), "review summary")
        XCTAssertTrue(text(containing: "Give this recipe a title").exists, "title warning")
        XCTAssertTrue(text(containing: "1 row is marked to check").exists, "flag count")
        XCTAssertTrue(text(containing: "didn't match the caption exactly").exists, "needs-review warning")
        let flag = text(containing: "Shortened to fit")
        scrollTo(flag, up: true)
        XCTAssertTrue(flag.exists, "orange flag on the long ingredient")
        snap("m3-03-review-flag")

        // Fix the flagged row and name the recipe
        let longField = field("Ingredient name", 3)
        replaceText(longField, with: "fresh basil leaves")
        XCTAssertEqual(longField.value as? String, "fresh basil leaves")
        waitGone(flag, "flag after editing the row")
        snap("m3-04a-flag-cleared")
        scrollTo(titleField(), up: false)
        titleField().tap(); titleField().typeText("Parmesan orzo")
        let summary = text(containing: "Nothing flagged")
        scrollTo(summary, up: false)
        waitFor(summary, "summary after fix")
        snap("m3-04-review-edited")
        app.navigationBars.buttons["Save"].tap()
        waitFor(app.staticTexts["Toast the orzo in butter."], "saved recipe's detail")
        snap("m3-05-saved-detail")

        let id = try XCTUnwrap(recipeID(titled: "Parmesan orzo"))
        let saved = recipeJSON(id)
        let rows = saved["ingredients"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map { $0["raw_text"] as? String }[1], "½ cup parmesan", "wording kept")
        XCTAssertTrue(rows[2]["quantity"] is NSNull, "salt to taste has no amount")
        XCTAssertEqual(rows[3]["name"] as? String, "fresh basil leaves")
    }

    func test4ImportFailureEnterManually() throws {
        guard let failing = ProcessInfo.processInfo.environment["WALKTHROUGH_FAILING_API_URL"],
              let failingURL = URL(string: failing) else {
            throw XCTSkip("Set WALKTHROUGH_FAILING_API_URL to a server whose extractor is down.")
        }
        resetRecipes()
        launch(api: failingURL)
        waitFor(app.staticTexts["No Recipes Yet"], "empty list")
        openAdd("Import Caption")
        waitFor(app.navigationBars["Import Caption"], "import screen")
        let editor = app.textViews["Caption"]
        editor.tap()
        editor.typeText("Quick toast\nIngredients:\n- 1 slice bread\nMethod:\n1. Toast it.")
        field("Instagram link").tap(); field("Instagram link").typeText("instagram.com/p/WALKfail1")
        app.navigationBars.buttons["Read Recipe"].tap()
        waitFor(app.buttons["Enter Manually Instead"], "import error", timeout: 60)
        snap("m3-06-import-failed")
        let message = text(containing: "extraction is unavailable")
        scrollTo(message, up: false)
        XCTAssertTrue(message.exists, "the server's error message is shown")
        snap("m3-06b-import-failed-message")
        XCTAssertTrue((app.textViews["Caption"].value as? String)?.contains("Quick toast") == true, "caption kept")
        app.buttons["Enter Manually Instead"].tap()
        waitFor(app.navigationBars["New Recipe"], "manual editor")
        // The Notes field, found by the caption text it should now hold.
        let notes = app.descendants(matching: .any).matching(NSPredicate(
            format: "value CONTAINS '1 slice bread' AND (elementType == %d OR elementType == %d)",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
        scrollTo(notes, up: true)
        XCTAssertTrue(notes.exists, "caption in Notes")
        XCTAssertTrue((field("Instagram link").value as? String)?.contains("WALKfail1") == true, "link kept")
        snap("m3-07-enter-manually")
        scrollTo(titleField(), up: false)
        titleField().tap(); titleField().typeText("Quick toast")
        app.navigationBars.buttons["Save"].tap()
        waitFor(recipe("Quick toast"), "manually saved recipe in list")
        snap("m3-08-manual-saved")
        let id = try XCTUnwrap(recipeID(titled: "Quick toast"))
        XCTAssertTrue((recipeJSON(id)["notes"] as? String)?.contains("Toast it.") == true)
    }
}
