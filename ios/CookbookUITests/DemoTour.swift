import XCTest

/// A paced tour of the MVP for a screen recording: list, import an Instagram reel through
/// the in-app browser (DEMO_REEL_URL, optional), import a pasted caption (real extractor),
/// review and save, search by ingredient, create by hand (a missing amount
/// stays missing), edit, the duplicate warning, and delete. It writes `start` and `end`
/// marker files into DEMO_MARK_DIR so a recorder can skip install and launch time.
/// It deletes every recipe on its server, so point it only at a throwaway dev-mode backend.
///
///   TEST_RUNNER_DEMO_MARK_DIR=/tmp/demo TEST_RUNNER_DEMO_API_URL=http://127.0.0.1:8105 \
///   TEST_RUNNER_DEMO_REEL_URL=https://www.instagram.com/reel/… \
///   xcodebuild test -scheme Screenshots -only-testing:CookbookUITests/DemoTour ...
final class DemoTour: XCTestCase {
    private var app: XCUIApplication!
    private var apiURL: URL!
    private var markDir: URL!

    private static let pancakeLink = "https://www.instagram.com/reel/DEMOpancake1/"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["DEMO_MARK_DIR"], !dir.isEmpty,
              let api = env["DEMO_API_URL"], let url = URL(string: api) else {
            throw XCTSkip("Set DEMO_MARK_DIR and DEMO_API_URL (a throwaway dev-mode server).")
        }
        markDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: markDir, withIntermediateDirectories: true)
        apiURL = url
    }

    // MARK: Helpers

    /// A pause so a viewer can follow along.
    private func beat(_ seconds: TimeInterval = 1.5) { Thread.sleep(forTimeInterval: seconds) }

    private func mark(_ name: String) {
        try? Data().write(to: markDir.appendingPathComponent(name))
    }

    private func waitFor(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) {
        if !element.waitForExistence(timeout: timeout) {
            mark("end")
            XCTFail("\(what) didn't appear", file: file, line: line)
        }
    }

    private func recipe(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func field(_ label: String, _ index: Int = 0) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)", label,
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue))
            .element(boundBy: index)
    }

    private func titleField() -> XCUIElement { app.textFields.firstMatch }

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

    private func openAdd(_ item: String) {
        app.navigationBars.buttons["Add Recipe"].tap()
        waitFor(app.buttons[item], "\(item) menu item", timeout: 5)
        beat(0.8)
        app.buttons[item].tap()
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

    private func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }

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
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0,
                      data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        return result
    }

    private func resetRecipes() {
        while true {
            let items = ((call("GET", "v1/recipes").1 as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            if items.isEmpty { return }
            for item in items { call("DELETE", "v1/recipes/\(item["id"] as! String)") }
        }
    }

    private func seed(_ title: String, ingredients: [(Double?, String?, String)], steps: [String],
                      source: String? = nil) {
        var body: [String: Any] = [
            "title": title,
            "ingredients": ingredients.map { qty, unit, name -> [String: Any] in
                var row: [String: Any] = ["name": name]
                if let qty { row["quantity"] = qty }
                if let unit { row["unit"] = unit }
                return row
            },
            "steps": steps.map { ["instruction": $0] },
        ]
        if let source { body["source_url"] = source }
        XCTAssertEqual(call("POST", "v1/recipes", body).0, 201, "seed \(title)")
    }

    // MARK: The tour

    func testTour() throws {
        resetRecipes()
        seed("Miso salmon bowl",
             ingredients: [(2, nil, "salmon fillets"), (1, "tbsp", "white miso"), (2, "cups", "cooked rice")],
             steps: ["Brush the salmon with miso.", "Broil for 8 minutes.", "Serve over rice."])
        seed("Banana oat pancakes",
             ingredients: [(2, nil, "ripe bananas"), (1, "cup", "rolled oats"), (2, nil, "eggs")],
             steps: ["Blend everything.", "Cook small pancakes in a hot pan."],
             source: Self.pancakeLink)
        seed("Tomato basil pasta",
             ingredients: [(200, "g", "spaghetti"), (3, nil, "tomatoes"), (nil, nil, "fresh basil")],
             steps: ["Cook the pasta.", "Toss with tomatoes and basil."])

        app = XCUIApplication()
        app.launchArguments = ["-serverURL", apiURL.absoluteString]
        app.launchEnvironment["COOKBOOK_API_URL"] = apiURL.absoluteString
        app.launch()
        waitFor(recipe("Tomato basil pasta"), "seeded list")
        mark("start")
        beat(2.5)

        // 1. Import a reel: the post opens in the logged-out in-app browser, Import Recipe
        // reads its caption, the extractor drafts it, and the user reviews and saves.
        if let reel = ProcessInfo.processInfo.environment["DEMO_REEL_URL"], !reel.isEmpty {
            openAdd("Import from Instagram Link")
            let linkField = app.alerts["Import from Instagram"].textFields.firstMatch
            waitFor(linkField, "link prompt", timeout: 5)
            linkField.typeText(reel)
            beat(1)
            app.alerts["Import from Instagram"].buttons["Open"].tap()
            waitFor(app.navigationBars["Instagram"], "in-app browser")
            let importButton = app.buttons["Import Recipe"]
            waitFor(importButton, "Import Recipe button")
            let loaded = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: importButton)
            XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 30), .completed, "page loaded")
            beat(3)
            importButton.tap()
            waitFor(app.navigationBars["Review Recipe"], "review screen (reel)", timeout: 90)
            beat(2.5)
            app.swipeUp()
            beat(1.5)
            app.swipeUp()
            beat(1.5)
            app.navigationBars.buttons["Save"].tap()
            waitFor(app.staticTexts["Ingredients"], "saved reel recipe")
            beat(2)
            app.swipeUp()
            beat(1.5)
            back()
            beat(1.5)
        }

        // 2. Import a pasted caption.
        openAdd("Import Caption")
        waitFor(app.navigationBars["Import Caption"], "import screen")
        beat(0.8)
        let caption = app.textViews["Caption"]
        caption.tap()
        caption.typeText("""
        Crispy lemon garlic chickpeas 🍋
        - 1 can chickpeas
        - 2 tbsp olive oil
        - salt to taste
        Toss with the oil and salt. Roast at 425F for 25 minutes.
        """)
        beat()
        app.navigationBars.buttons["Read Recipe"].tap()
        waitFor(app.navigationBars["Review Recipe"], "review screen", timeout: 60)
        beat(2.5)
        app.swipeUp()
        beat(1.5)
        app.swipeUp()
        beat(1.5)
        app.navigationBars.buttons["Save"].tap()
        waitFor(app.staticTexts["Ingredients"], "saved recipe")
        beat(2)
        app.swipeUp()
        beat(1.5)
        back()
        waitFor(recipe("Crispy lemon garlic chickpeas"), "imported recipe in the list")
        beat(1.5)

        // 3. Search by an ingredient that isn't in any title.
        let search = app.searchFields.firstMatch
        search.tap()
        beat(0.5)
        search.typeText("oats")
        waitFor(recipe("Banana oat pancakes"), "ingredient search result")
        beat(2)
        tapFirst(["Cancel", "Close", "close"], "search cancel")
        beat(1)

        // 4. Create by hand: "soy sauce" has no amount, and it stays that way.
        openAdd("New Recipe")
        waitFor(app.navigationBars["New Recipe"], "new recipe editor")
        titleField().tap(); titleField().typeText("Weeknight fried rice")
        field("Quantity").tap(); field("Quantity").typeText("2")
        field("Unit").tap(); field("Unit").typeText("cups")
        field("Ingredient name").tap(); field("Ingredient name").typeText("cooked rice")
        app.buttons["Add Ingredient"].tap()
        field("Ingredient name", 1).tap(); field("Ingredient name", 1).typeText("soy sauce")
        field("Step 1").tap(); field("Step 1").typeText("Fry the rice in a hot pan with the soy sauce.")
        beat()
        app.navigationBars.buttons["Save"].tap()
        waitFor(recipe("Weeknight fried rice"), "created recipe")
        beat(1)
        recipe("Weeknight fried rice").tap()
        waitFor(app.staticTexts["Ingredients"], "created recipe detail")
        beat(2)

        // 5. Edit.
        app.navigationBars.buttons["Edit"].tap()
        waitFor(app.navigationBars["Edit Recipe"], "editor")
        replaceText(titleField(), with: "Weeknight egg fried rice")
        beat()
        app.navigationBars.buttons["Save"].tap()
        waitFor(app.staticTexts["Weeknight egg fried rice"], "edited title")
        beat(2)
        back()
        beat(1)

        // 6. Saving a post that's already in the cookbook warns and links to it.
        openAdd("New Recipe")
        waitFor(app.navigationBars["New Recipe"], "new recipe editor (duplicate)")
        titleField().tap(); titleField().typeText("Banana pancakes")
        field("Instagram link").tap(); field("Instagram link").typeText(Self.pancakeLink)
        beat()
        app.navigationBars.buttons["Save"].tap()
        waitFor(app.alerts["Already in your cookbook"], "duplicate alert")
        beat(2.5)
        app.alerts.buttons["Open Existing"].tap()
        waitFor(app.staticTexts["Blend everything."], "existing recipe")
        beat(2)
        back()
        beat(1)

        // 7. Delete, with a confirmation.
        waitFor(recipe("Weeknight egg fried rice"), "recipe to delete")
        recipe("Weeknight egg fried rice").press(forDuration: 1.2)
        waitFor(app.buttons["Delete"], "context menu")
        beat(1)
        app.buttons["Delete"].tap()
        waitFor(app.buttons["Delete Recipe"], "delete confirmation")
        beat(1.5)
        app.buttons["Delete Recipe"].tap()
        beat(2.5)
        mark("end")
    }
}
