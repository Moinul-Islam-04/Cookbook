import WebKit
import XCTest
@testable import Cookbook

/// TikTok links, hand-off and page reading. Offline, except LiveTikTokPageTests.
final class TikTokLinkTests: XCTestCase {
    private let post = "https://www.tiktok.com/@cookinginthemidwest/video/7696145792720997663"

    func testNormalizesLikeTheServer() {
        // Same canonical form as backend/app/source_urls.py.
        let cases = [
            post + "?lang=en": post,
            post + "/": post,
            "tiktok.com/@cookinginthemidwest/video/7696145792720997663": post,
            "https://m.tiktok.com/@cookinginthemidwest/video/7696145792720997663?is_from_webapp=1#x": post,
            "https://www.tiktok.com/@a.b_c/photo/7123456789012345678": "https://www.tiktok.com/@a.b_c/photo/7123456789012345678",
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TikTokLink.postURL(from: input)?.absoluteString, expected, input)
        }
    }

    func testRejectsAnythingButASinglePost() {
        for bad in ["https://www.tiktok.com/@cookinginthemidwest", "https://www.tiktok.com/@a/video/1",
                    "https://www.tiktok.com/@a/live/7696145792720997663", "https://vm.tiktok.com/ZMabc123/",
                    "https://www.tiktok.com.evil.com/@a/video/7696145792720997663",
                    "https://evil.com/www.tiktok.com/@a/video/7696145792720997663",
                    "https://u:p@www.tiktok.com/@a/video/7696145792720997663",
                    "https://www.tiktok.com:8443/@a/video/7696145792720997663", "hello world"] {
            XCTAssertNil(TikTokLink.postURL(from: bad), bad)
        }
    }

    func testRecognizesShortLinks() {
        XCTAssertTrue(TikTokLink.isShortLink("https://vm.tiktok.com/ZMabc123/"))
        XCTAssertTrue(TikTokLink.isShortLink("vt.tiktok.com/ZSabc"))
        XCTAssertTrue(TikTokLink.isShortLink("https://www.tiktok.com/t/ZTabc123/"))
        XCTAssertFalse(TikTokLink.isShortLink(post))
        XCTAssertFalse(TikTokLink.isShortLink("https://www.instagram.com/reel/C1a2B3c4D5e/"))
    }

    func testPlatformOfAPastedOrStoredLink() {
        XCTAssertEqual(PostPlatform.post(from: post + "?lang=en")?.platform, .tiktok)
        XCTAssertEqual(PostPlatform.of("https://www.instagram.com/reel/C1a2B3c4D5e/"), .instagram)
        XCTAssertEqual(PostPlatform.of(post), .tiktok)
        XCTAssertNil(PostPlatform.of("https://example.com/recipe"))
    }

    func testShareAndDeepLinkHandOff() {
        let shared = "Steak Cheese and Rice 🌮 \(post)?_r=1&_t=ZT-8abc #easyrecipes"
        XCTAssertEqual(ImportHandoff.postURL(urls: [], texts: [shared])?.absoluteString, post)
        let link = ImportHandoff.deepLink(for: URL(string: post)!)
        XCTAssertEqual(ImportHandoff.postURL(fromDeepLink: link)?.absoluteString, post)
        XCTAssertTrue(ImportHandoff.hasShortTikTokLink(urls: [], texts: ["look https://vm.tiktok.com/ZMabc123/"]))
        XCTAssertFalse(ImportHandoff.hasShortTikTokLink(urls: [URL(string: post)!], texts: []))
    }
}

final class TikTokPageTextTests: XCTestCase {
    func testDropsTheSeeMoreButtonText() {
        let page = TikTokPageText(description: "See moreSteak Cheese and Rice is easy to make! 🌮 INGREDIENTS 1 1/2 lbs steak")
        XCTAssertEqual(page.caption, "Steak Cheese and Rice is easy to make! 🌮 INGREDIENTS 1 1/2 lbs steak")
    }

    func testNoCaptionWhenThePageShowsNone() {
        XCTAssertNil(TikTokPageText(description: nil).caption)
        XCTAssertNil(TikTokPageText(description: "See more").caption)
    }

    func testDecodesTheInPageScriptsJSON() {
        let json = #"{"description":"Garlic noodles\n8 oz noodles\n4 cloves garlic"}"#
        XCTAssertEqual(PostPlatform.tiktok.caption(fromPageJSON: json), "Garlic noodles\n8 oz noodles\n4 cloves garlic")
        XCTAssertNil(PostPlatform.tiktok.caption(fromPageJSON: #"{"description":null}"#))
    }

    func testBrowserStaysOnTheSite() {
        XCTAssertTrue(PostPlatform.tiktok.allowsBrowsing(host: "www.tiktok.com"))
        XCTAssertTrue(PostPlatform.tiktok.allowsBrowsing(host: "m.tiktok.com"))
        XCTAssertFalse(PostPlatform.tiktok.allowsBrowsing(host: "tiktok.com.evil.com"))
        XCTAssertFalse(PostPlatform.tiktok.allowsBrowsing(host: "www.instagram.com"))
        XCTAssertFalse(PostPlatform.instagram.allowsBrowsing(host: "www.tiktok.com"))
    }
}

/// Loads a real TikTok post the way the in-app browser does (fresh, logged-out session) and
/// runs the app's page script on it, to catch TikTok changing its page. Skips unless
/// TIKTOK_PAGE_URL is set (TEST_RUNNER_TIKTOK_PAGE_URL for xcodebuild).
@MainActor
final class LiveTikTokPageTests: XCTestCase {
    func testReadsTheCaptionOffTheRealPage() async throws {
        guard let link = ProcessInfo.processInfo.environment["TIKTOK_PAGE_URL"], let url = URL(string: link) else {
            throw XCTSkip("Set TEST_RUNNER_TIKTOK_PAGE_URL to a public TikTok post.")
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.load(URLRequest(url: url))
        var caption: String?
        for _ in 0..<20 where caption == nil {
            try await Task.sleep(for: .seconds(1))
            if let json = try? await webView.evaluateJavaScript(PostPlatform.tiktok.extractionScript) as? String {
                caption = PostPlatform.tiktok.caption(fromPageJSON: json)
            }
        }
        let text = try XCTUnwrap(caption, "no caption on the page after 20 s")
        print("TIKTOK CAPTION (\(text.count) chars): \(text)")
        XCTAssertFalse(text.hasPrefix("See more"))
        XCTAssertGreaterThan(text.count, 20)
    }
}
