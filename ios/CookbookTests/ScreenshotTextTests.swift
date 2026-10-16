import UIKit
import XCTest
@testable import Cookbook

final class ScreenshotTextTests: XCTestCase {
    /// A line at a vertical position, in Vision's coordinates (origin bottom left).
    private func line(_ text: String, x: CGFloat = 0.05, top: CGFloat, height: CGFloat = 0.02, width: CGFloat = 0.5) -> ScreenshotText.Line {
        ScreenshotText.Line(text: text, box: CGRect(x: x, y: top - height, width: width, height: height))
    }

    // MARK: Ordering

    func testLinesComeOutTopToBottomWhateverTheInputOrder() {
        let lines = [
            line("2 eggs", top: 0.725),
            line("Ingredients", top: 0.75),
            line("1 1/2 cups flour", top: 0.70),
        ]
        XCTAssertEqual(ScreenshotText.text(from: lines), "Ingredients\n2 eggs\n1 1/2 cups flour")
    }

    func testPiecesOfOneRowJoinLeftToRight() {
        let lines = [
            line("cups flour", x: 0.12, top: 0.70),
            line("1½", x: 0.05, top: 0.701, width: 0.05),
        ]
        XCTAssertEqual(ScreenshotText.text(from: lines), "1½ cups flour")
    }

    func testABigGapBecomesABlankLine() {
        let lines = [
            line("Steps", top: 0.80),
            line("1. Whisk.", top: 0.775),   // normal line spacing: no blank line
            line("Enjoy!", top: 0.70),       // gap of more than a line: blank line
        ]
        XCTAssertEqual(ScreenshotText.text(from: lines), "Steps\n1. Whisk.\n\nEnjoy!")
    }

    func testTextIsTrimmedButNeverRewritten() {
        let lines = [line("  ¼ tsp salt (1.5 g) ", top: 0.5), line("   ", top: 0.4)]
        XCTAssertEqual(ScreenshotText.text(from: lines), "¼ tsp salt (1.5 g)")
        XCTAssertEqual(ScreenshotText.text(from: []), "")
    }

    // MARK: Several screenshots

    func testPagesJoinInPickedOrder() {
        XCTAssertEqual(
            ScreenshotText.join(pages: ["Ingredients\n2 eggs", "", "Steps\n1. Whisk."]),
            "Ingredients\n2 eggs\n\nSteps\n1. Whisk.")
    }

    func testRepeatedLinesWhereScreenshotsOverlapAreDroppedOnce() {
        let first = "Ingredients\n2 eggs\n1 cup milk\n3 tbsp sugar"
        let second = "1 cup milk\n3 tbsp sugar\nSteps\n1. Whisk."
        XCTAssertEqual(
            ScreenshotText.join(pages: [first, second]),
            "Ingredients\n2 eggs\n1 cup milk\n3 tbsp sugar\nSteps\n1. Whisk.")
    }

    func testAShortSingleRepeatedLineIsKept() {
        // One short line might genuinely appear twice ("Salt"), so it isn't treated as overlap.
        XCTAssertEqual(ScreenshotText.join(pages: ["Dough\nSalt", "Salt\nSugar"]), "Dough\nSalt\n\nSalt\nSugar")
    }

    func testOneLongRepeatedLineCountsAsOverlap() {
        let long = "Bake for 25 minutes at 180°C until golden."
        XCTAssertEqual(ScreenshotText.join(pages: ["Steps\n" + long, long + "\nEnjoy"]), "Steps\n\(long)\nEnjoy")
    }

    // MARK: Amounts to check

    func testMixedNumbersThatLostTheirSpaceArePointedOut() {
        let text = "- 11/2 cups flour\n- 13/4 cups milk\n- 11/2 tsp salt\n- 21/2 tbsp oil"
        XCTAssertEqual(ScreenshotText.possibleMixedNumbers(in: text), ["11/2", "13/4", "21/2"])
    }

    func testOrdinaryAmountsAreNotPointedOut() {
        let text = "1 1/2 cups flour\n3/4 cup milk\n10/12 dates\n15/2 min\n2023/24 season\n1.5/2 kg\n½ tsp"
        // 15/2: the second digit isn't smaller than the denominator, so it can't be "1 5/2".
        XCTAssertEqual(ScreenshotText.possibleMixedNumbers(in: text), [])
    }

    // MARK: Merging into the caption

    func testRecognizedTextIsAddedAfterWhatIsThere() {
        XCTAssertEqual(ScreenshotText.merged(existing: "", recognized: "2 eggs\n"), "2 eggs")
        XCTAssertEqual(ScreenshotText.merged(existing: "Pancakes\n", recognized: "2 eggs"), "Pancakes\n\n2 eggs")
        XCTAssertEqual(ScreenshotText.merged(existing: "Pancakes", recognized: "  \n"), "Pancakes",
                       "no text found leaves the caption as it was")
    }

    // MARK: Vision on a generated image

    func testVisionReadsAGeneratedScreenshot() async throws {
        // "1 1/2" is left out on purpose: the Simulator's Vision read it as "11/2" from this
        // image (macOS Vision read it correctly). That's why the screen asks the user to check
        // amounts; the test pins down ordering and plain numbers.
        let lines = ["Lemon Pancakes", "Ingredients", "2 eggs", "3/4 cup ricotta", "Steps", "Whisk everything together."]
        let size = CGSize(width: 900, height: 700)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.black,
            ]
            for (index, text) in lines.enumerated() {
                (text as NSString).draw(at: CGPoint(x: 40, y: 40 + CGFloat(index) * 100), withAttributes: attributes)
            }
        }
        let png = try XCTUnwrap(image.pngData())

        let text = try await ScreenshotText.recognize(imageData: png)
        let recognized = text.split(separator: "\n").map(String.init)
        // Every line in order, numbers as drawn. The 100 px spacing is about two line heights,
        // so there's a blank line between each (split() drops them).
        XCTAssertEqual(recognized, lines, "got: \(text)")
        XCTAssertTrue(text.contains("Ingredients\n\n2 eggs"), "big gaps become blank lines; got: \(text)")
    }

    func testNotAnImageIsAFailure() async {
        do {
            _ = try await ScreenshotText.recognize(imageData: Data("not an image".utf8))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? ScreenshotText.Failure, .unreadableImage)
        }
    }
}
