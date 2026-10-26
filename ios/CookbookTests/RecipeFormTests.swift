import XCTest
@testable import Cookbook

/// The form → request rules, checked without a server.
final class QuantityTextTests: XCTestCase {
    func testParsesWholeDecimalAndFractions() {
        XCTAssertEqual(QuantityText.parse("2"), 2)
        XCTAssertEqual(QuantityText.parse("1.5"), Decimal(string: "1.5"))
        XCTAssertEqual(QuantityText.parse("1 1/2"), Decimal(string: "1.5"))
        XCTAssertEqual(QuantityText.parse(" 1/2 "), Decimal(string: "0.5"))
    }

    func testRoundsToTheServersThreeDecimalPlaces() {
        XCTAssertEqual(QuantityText.parse("1/3"), Decimal(string: "0.333"))
    }

    func testRejectsWhatTheServerWould() {
        for bad in ["0", "2abc", "1/0", "/2", "-1", "1 2 3", "", "½"] {
            XCTAssertNil(QuantityText.parse(bad), bad)
        }
    }

    func testFormatsWithoutTrailingZeros() {
        XCTAssertEqual(QuantityText.format(Decimal(string: "1.500")!), "1.5")
        XCTAssertEqual(QuantityText.format(2), "2")
    }
}

final class RecipeFormTests: XCTestCase {
    private func loadedRecipe() throws -> (Recipe, RecipeForm) {
        let recipe = try decode(Recipe.self, Fixtures.recipeJSON)
        return (recipe, RecipeForm(recipe: recipe))
    }

    func testCreateBodyTrimsAndDropsBlankRows() {
        var form = RecipeForm()
        form.title = "  Pasta "
        form.notes = "   "
        form.ingredients = [.init(quantity: "", unit: "", name: "salt"), .init()]
        form.steps = [.init(instruction: " Boil water. "), .init(instruction: "  ")]

        let body = form.createBody()
        XCTAssertEqual(body.title, "Pasta")
        XCTAssertNil(body.notes)
        XCTAssertEqual(body.ingredients, [IngredientInput(name: "salt", quantity: nil, unit: nil, rawText: nil)])
        XCTAssertEqual(body.steps, [StepInput(instruction: "Boil water.")])
    }

    func testValidationUsesServerFieldPaths() {
        var form = RecipeForm()
        form.ingredients = [.init(), .init(quantity: "2abc", unit: "", name: ""), .init(name: "salt")]
        let errors = form.validationErrors
        XCTAssertNotNil(errors["title"])
        // Blank rows aren't sent, so the bad row is index 0 on the wire.
        XCTAssertNotNil(errors["ingredients.0.quantity"])
        XCTAssertNotNil(errors["ingredients.0.name"])
        XCTAssertNil(errors["ingredients.1.name"])
    }

    func testReviewedImportNeedsIngredientsAndSteps() {
        var form = RecipeForm()
        form.title = "x"
        XCTAssertNotNil(form.validationErrors(reviewedImport: true)["ingredients"])
        XCTAssertNotNil(form.validationErrors(reviewedImport: true)["steps"])
        XCTAssertTrue(form.validationErrors(reviewedImport: false).isEmpty)
    }

    func testTitleOnlyEditSendsOnlyTheTitle() throws {
        let (recipe, baseline) = try loadedRecipe()
        var form = baseline
        form.title = "Tomato pasta v2"
        let patch = form.patchBody(version: recipe.version, against: baseline)
        XCTAssertEqual(patch.title, "Tomato pasta v2")
        XCTAssertNil(patch.ingredients)
        XCTAssertNil(patch.steps)
        let sent = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(patch)) as? NSDictionary
        XCTAssertEqual(sent, ["title": "Tomato pasta v2", "version": 3], "untouched keys are omitted")
    }

    func testClearingNotesAndLinkSendsExplicitNull() throws {
        let (recipe, baseline) = try loadedRecipe()
        var form = baseline
        form.notes = "  "
        let json = try wireJSON(form.patchBody(version: recipe.version, against: baseline))
        XCTAssertTrue(json.contains(#""notes":null"#), json)
    }

    func testUntouchedRowsKeepTheirWording() throws {
        let (recipe, baseline) = try loadedRecipe()
        var form = baseline
        form.ingredients[1].quantity = "2"
        let rows = try XCTUnwrap(form.patchBody(version: recipe.version, against: baseline).ingredients)
        XCTAssertEqual(rows[0].rawText, "salt to taste", "untouched row sends original raw_text")
        XCTAssertNil(rows[1].rawText, "edited row lets the server recompose it")
        XCTAssertEqual(rows[1].quantity, 2)
    }

    func testTypedFractionKeepsItsWording() {
        // Milestone 1 bug: "1/3 cup" was saved as "0.333 cup".
        var form = RecipeForm()
        form.title = "Lemon"
        form.ingredients = [.init(quantity: "1/3", unit: "cup", name: "lemon juice")]
        let row = form.createBody().ingredients[0]
        XCTAssertEqual(row.rawText, "1/3 cup lemon juice")
        XCTAssertEqual(row.quantity, Decimal(string: "0.333"))
    }

    func testDraftReviewCarriesFlagsUntilEdited() throws {
        let draft = try decode(ImportDraft.self, Fixtures.draftJSON)
        var form = RecipeForm(draft: draft)
        XCTAssertEqual(form.title, "Garlic noodles")
        XCTAssertEqual(form.ingredients[0].quantity, "8")
        XCTAssertFalse(form.ingredients[0].needsReview)
        XCTAssertTrue(form.ingredients[1].needsReview)

        form.ingredients[1].quantity = "3"
        XCTAssertFalse(form.ingredients[1].needsReview, "editing a flagged row clears its flag")
        let patch = form.draftPatch(version: draft.version)
        XCTAssertEqual(patch.ingredients?.map(\.rawText), ["8 oz noodles", "3 cloves garlic"])
        XCTAssertEqual(patch.ingredients?.map(\.needsReview), [false, false])
    }

    func testTitleOnlyEditKeepsIngredientNotes() throws {
        // Before servings/notes were wired up, any ingredient edit resent the rows without
        // their notes, and the server replaced them.
        let (recipe, baseline) = try loadedRecipe()
        XCTAssertEqual(baseline.ingredients[1].note, "extra virgin")
        var form = baseline
        form.ingredients[0].name = "sea salt"
        let rows = try XCTUnwrap(form.patchBody(version: recipe.version, against: baseline).ingredients)
        XCTAssertEqual(rows.map(\.note), [nil, "extra virgin"])
        XCTAssertEqual(rows[1].rawText, "1 1/2 tbsp olive oil, extra virgin")
    }

    func testEditingANoteLetsTheServerRecomposeTheLine() throws {
        let (recipe, baseline) = try loadedRecipe()
        var form = baseline
        form.ingredients[1].note = "light"
        let rows = try XCTUnwrap(form.patchBody(version: recipe.version, against: baseline).ingredients)
        XCTAssertEqual(rows[1].note, "light")
        XCTAssertNotEqual(rows[1].rawText, "1 1/2 tbsp olive oil, extra virgin", "the old note must not survive in raw_text")
    }

    func testServingsAreSentOnlyWhenChangedAndCanBeCleared() throws {
        let (recipe, baseline) = try loadedRecipe()
        XCTAssertEqual(baseline.servings, "4")
        var form = baseline
        form.title = "x"
        XCTAssertFalse(try wireJSON(form.patchBody(version: recipe.version, against: baseline)).contains("servings"))
        form.servings = " 6 "
        XCTAssertTrue(try wireJSON(form.patchBody(version: recipe.version, against: baseline)).contains(#""servings":6"#))
        form.servings = ""
        let json = try wireJSON(form.patchBody(version: recipe.version, against: baseline))
        XCTAssertTrue(json.contains(#""servings":null"#), json)
    }

    func testServingsValidation() {
        var form = RecipeForm()
        form.title = "x"
        for bad in ["0", "1001", "2.5", "four"] {
            form.servings = bad
            XCTAssertNotNil(form.validationErrors["servings"], bad)
        }
        form.servings = "12"
        XCTAssertTrue(form.validationErrors.isEmpty)
        XCTAssertEqual(form.createBody().servings, 12)
    }

    func testDraftReviewKeepsServingsNotesAndSubRecipes() throws {
        let draft = try decode(ImportDraft.self, Fixtures.draftJSON)
        var form = RecipeForm(draft: draft)
        XCTAssertEqual(form.servings, "2")
        XCTAssertEqual(form.ingredients[1].note, "minced")

        let patch = form.draftPatch(version: draft.version)
        XCTAssertEqual(patch.ingredients?.map(\.note), [nil, "minced"])
        XCTAssertEqual(patch.ingredients?.map(\.subRecipe), [nil, 0])
        let body = form.createBody(draftID: draft.id)
        XCTAssertEqual(body.servings, 2)
        XCTAssertEqual(body.ingredients.map(\.note), [nil, "minced"])

        // Clearing servings on a draft must send null: an omitted key means "use the draft's".
        form.servings = ""
        let json = try wireJSON(form.createBody(draftID: draft.id))
        XCTAssertTrue(json.contains(#""servings":null"#), json)
    }

    func testEmptyDraftGivesOneBlankRowToFill() throws {
        let json = Fixtures.draftJSON
            .replacingOccurrences(of: #"\"ingredients\": \[[\s\S]*?\],\n  \"steps\": \[[\s\S]*?\],"#,
                                  with: #""ingredients": [], "steps": [],"#, options: .regularExpression)
        let form = RecipeForm(draft: try decode(ImportDraft.self, json))
        XCTAssertEqual(form.ingredients.count, 1)
        XCTAssertTrue(form.ingredients[0].isBlank)
        XCTAssertEqual(form.steps.count, 1)
    }
}
