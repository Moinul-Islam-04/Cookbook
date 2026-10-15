import XCTest
@testable import Cookbook

final class InstagramLinkTests: XCTestCase {
    func testNormalizesPostAndReelLinks() {
        let cases = [
            "https://www.instagram.com/reel/C1a2B3c4D5e/?igsh=MTc4": "https://www.instagram.com/reel/C1a2B3c4D5e/",
            "instagram.com/p/C1a2B3c4D5e": "https://www.instagram.com/p/C1a2B3c4D5e/",
            "https://www.instagram.com/chef.ann/reel/C1a2B3c4D5e/": "https://www.instagram.com/reel/C1a2B3c4D5e/",
            "https://www.instagram.com/reels/C1a2B3c4D5e": "https://www.instagram.com/reel/C1a2B3c4D5e/",
        ]
        for (input, expected) in cases {
            XCTAssertEqual(InstagramLink.postURL(from: input)?.absoluteString, expected, input)
        }
    }

    func testRejectsAnythingButASinglePost() {
        for bad in ["https://www.tiktok.com/@a/video/1", "https://www.instagram.com/chef.ann/",
                    "https://evil.com/www.instagram.com/p/C1a2B3c4D5e/",
                    "https://www.instagram.com.evil.com/p/C1a2B3c4D5e/",
                    "https://u:p@www.instagram.com/p/C1a2B3c4D5e/", "hello world"] {
            XCTAssertNil(InstagramLink.postURL(from: bad), bad)
        }
    }
}

final class InstagramPageTextTests: XCTestCase {
    private let og = #"1,234 likes, 56 comments - chef.ann on May 1, 2026: "Garlic noodles 🍜\n\nIngredients:\n- 8 oz noodles\n- 4 cloves garlic\n\nSteps:\n1. Boil noodles.". "#

    func testReadsTheCaptionFromMetaTags() {
        let caption = InstagramPageText.quotedCaption(in: og)
        XCTAssertEqual(caption?.hasPrefix("Garlic noodles 🍜"), true)
        XCTAssertEqual(caption?.hasSuffix("1. Boil noodles."), true, "trailing quote and period stripped")
        XCTAssertEqual(InstagramPageText.quotedCaption(in: "Chef Ann on Instagram: \u{201C}Easy chili: 1 lb beef, 2 cans beans\u{201D}"),
                       "Easy chili: 1 lb beef, 2 cans beans", "og:title curly quotes")
        XCTAssertNil(InstagramPageText.quotedCaption(in: "See photos and videos from Chef Ann"), "profile page")
    }

    func testPrefersTheVisibleHeadingOverTruncatedMeta() {
        let page = InstagramPageText(heading: "Garlic noodles. Ingredients: 8 oz noodles, 4 cloves garlic",
                                     ogDescription: og, ogTitle: nil, loginWall: false)
        XCTAssertEqual(page.caption, page.heading)
        let short = InstagramPageText(heading: "Reel", ogDescription: og, ogTitle: nil, loginWall: false)
        XCTAssertEqual(short.caption?.hasPrefix("Garlic noodles"), true, "short heading falls back to og:description")
    }

    func testLoginWallHasNoCaption() {
        XCTAssertNil(InstagramPageText(heading: nil, ogDescription: nil, ogTitle: nil, loginWall: true).caption)
    }

    func testDecodesTheInPageScriptsJSON() throws {
        let json = #"{"heading":null,"ogDescription":"10 likes, 0 comments - a on Jan 1, 2026: \"Toast: bread, butter. Toast it.\"","ogTitle":null,"loginWall":false}"#
        let page = try JSONDecoder().decode(InstagramPageText.self, from: Data(json.utf8))
        XCTAssertEqual(page.caption, "Toast: bread, butter. Toast it.", "caption keeps its own period")
    }
}

final class PairingCodeTests: XCTestCase {
    private func code(_ payload: String) -> String {
        PairingCode.prefix + Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testDecodesServerAndToken() {
        let parsed = PairingCode("  " + code(#"{"server":"https://mac.example.ts.net","token":"ckb_abc"}"#) + "\n")
        XCTAssertEqual(parsed?.server.absoluteString, "https://mac.example.ts.net")
        XCTAssertEqual(parsed?.token, "ckb_abc")
    }

    func testRejectsMalformedCodes() {
        XCTAssertNil(PairingCode("ckb_abc"), "a bare token isn't a pairing code")
        XCTAssertNil(PairingCode(PairingCode.prefix + "not base64!"))
        XCTAssertNil(PairingCode(code(#"{"server":"ftp://mac","token":"ckb_abc"}"#)), "only http(s)")
        XCTAssertNil(PairingCode(code(#"{"server":"https://mac","token":"abc"}"#)), "token must look like ckb_")
    }
}
