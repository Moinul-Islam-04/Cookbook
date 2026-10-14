import Foundation
var failures = 0
func check(_ c: Bool, _ m: String, line: Int = #line) { print(c ? "  ok   \(m)" : "  FAIL \(m) (line \(line))"); if !c { failures += 1 } }

print("InstagramLink")
check(InstagramLink.postURL(from: "https://www.instagram.com/reel/C1a2B3c4D5e/?igsh=MTc4")?.absoluteString == "https://www.instagram.com/reel/C1a2B3c4D5e/", "reel with tracking")
check(InstagramLink.postURL(from: "instagram.com/p/C1a2B3c4D5e")?.absoluteString == "https://www.instagram.com/p/C1a2B3c4D5e/", "no scheme")
check(InstagramLink.postURL(from: "https://www.instagram.com/chef.ann/reel/C1a2B3c4D5e/")?.absoluteString == "https://www.instagram.com/reel/C1a2B3c4D5e/", "username segment")
check(InstagramLink.postURL(from: "https://www.instagram.com/reels/C1a2B3c4D5e") != nil, "reels/")
for bad in ["https://www.tiktok.com/@a/video/1", "https://www.instagram.com/chef.ann/", "https://evil.com/www.instagram.com/p/C1a2B3c4D5e/",
            "https://www.instagram.com.evil.com/p/C1a2B3c4D5e/", "https://u:p@www.instagram.com/p/C1a2B3c4D5e/", "hello world"] {
    check(InstagramLink.postURL(from: bad) == nil, "rejects \(bad)")
}

print("Caption from page text")
let og = #"1,234 likes, 56 comments - chef.ann on May 1, 2026: "Garlic noodles 🍜\n\nIngredients:\n- 8 oz noodles\n- 4 cloves garlic\n\nSteps:\n1. Boil noodles.". "#
check(InstagramPageText.quotedCaption(in: og)?.hasPrefix("Garlic noodles 🍜") == true, "og:description caption")
check(InstagramPageText.quotedCaption(in: og)?.hasSuffix("1. Boil noodles.") == true, "trailing quote and period stripped")
check(InstagramPageText.quotedCaption(in: "Chef Ann on Instagram: \u{201C}Easy chili: 1 lb beef, 2 cans beans\u{201D}") == "Easy chili: 1 lb beef, 2 cans beans", "og:title curly quotes")
check(InstagramPageText.quotedCaption(in: "See photos and videos from Chef Ann") == nil, "profile description has no caption")
let fromHeading = InstagramPageText(heading: "Garlic noodles. Ingredients: 8 oz noodles, 4 cloves garlic", ogDescription: og, ogTitle: nil, loginWall: false)
check(fromHeading.caption == fromHeading.heading, "visible heading preferred (not truncated)")
let shortHeading = InstagramPageText(heading: "Reel", ogDescription: og, ogTitle: nil, loginWall: false)
check(shortHeading.caption?.hasPrefix("Garlic noodles") == true, "short heading falls back to og:description")
check(InstagramPageText(heading: nil, ogDescription: nil, ogTitle: nil, loginWall: true).caption == nil, "login wall → nil")
let json = #"{"heading":null,"ogDescription":"10 likes, 0 comments - a on Jan 1, 2026: \"Toast: bread, butter. Toast it.\"","ogTitle":null,"loginWall":false}"#
check((try? JSONDecoder().decode(InstagramPageText.self, from: Data(json.utf8)))?.caption == "Toast: bread, butter. Toast it.", "decodes script JSON (caption keeps its own period)")
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
