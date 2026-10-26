import XCTest
@testable import Cookbook

final class IngredientTextTests: XCTestCase {
    private func amount(_ raw: String, _ name: String) -> String? {
        IngredientText.amountRange(in: raw, name: name).map { String(raw[$0]) }
    }

    func testAmountIsTheTextBeforeTheName() {
        XCTAssertEqual(amount("1.5KG Extra Lean Beef Mince", "Extra Lean Beef Mince"), "1.5KG")
        XCTAssertEqual(amount("1 Tsp Salt & 200g Egg Whites", "Salt & 200g Egg Whites"), "1 Tsp")
        XCTAssertEqual(amount("1/3 cup fresh lemon juice", "fresh lemon juice"), "1/3 cup")
        XCTAssertEqual(amount("1 1/2 lb chicken", "CHICKEN"), "1 1/2 lb", "case-insensitive")
    }

    func testFallsBackToALeadingNumber() {
        XCTAssertEqual(amount("2 cloves garlic, smashed", "garlic cloves"), "2")
        XCTAssertEqual(amount("½ cup soy sauce", ""), "½")
    }

    func testNoAmountNoEmphasis() {
        XCTAssertNil(amount("salt to taste", "salt"))
        XCTAssertNil(amount("Juice of 1 lemon", "lemon"), "doesn't start with an amount")
        XCTAssertNil(amount("Chives", "Chives"))
    }

    func testNeverChangesTheText() {
        let raw = "25g Sriracha Mayonnaise (per burrito - optional)"
        let text = IngredientText.emphasized(rawText: raw, name: "Sriracha Mayonnaise", quantity: 25, unit: "g")
        XCTAssertEqual(String(text.characters), raw)
        let bold = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(text[$0.range].characters) }
        XCTAssertEqual(bold, ["25g"])
    }

    func testUnmeasuredRowIsPlain() {
        let text = IngredientText.emphasized(rawText: "2 eggs", name: "eggs", quantity: nil, unit: nil)
        XCTAssertTrue(text.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    func testNoteShownOnlyWhenTheLineDoesntSayIt() {
        XCTAssertNil(IngredientText.separateNote(rawText: "2 onions, Finely Chopped", note: "finely chopped"))
        XCTAssertEqual(IngredientText.separateNote(rawText: "2 onions", note: "diced"), "diced")
        XCTAssertNil(IngredientText.separateNote(rawText: "2 onions", note: nil))
        XCTAssertNil(IngredientText.separateNote(rawText: "2 onions", note: "  "))
    }
}
