import XCTest
@testable import Cookbook

/// Share extension → app hand-off (ios/Shared/ImportHandoff.swift). Offline.
final class ImportHandoffTests: XCTestCase {
    private let reel = URL(string: "https://www.instagram.com/reel/C1a2B3c4D5e/")!

    func testFindsTheReelInASharedURL() {
        let shared = URL(string: "https://www.instagram.com/reel/C1a2B3c4D5e/?igsh=MTc4bmR5")!
        XCTAssertEqual(ImportHandoff.postURL(urls: [shared], texts: []), reel)
    }

    func testFindsTheLinkInsideSharedText() {
        let text = "Check out this reel by @chef.ann https://www.instagram.com/reel/C1a2B3c4D5e/?igsh=MTc4bmR5 🍜"
        XCTAssertEqual(ImportHandoff.postURL(urls: [], texts: [text]), reel)
        XCTAssertEqual(ImportHandoff.postURL(urls: [], texts: ["instagram.com/p/C1a2B3c4D5e"])?.absoluteString,
                       "https://www.instagram.com/p/C1a2B3c4D5e/", "bare pasted link")
    }

    func testSkipsOtherLinksForTheInstagramOne() {
        let other = URL(string: "https://example.com/recipes/noodles")!
        let text = "via https://example.com and https://www.instagram.com/p/C1a2B3c4D5e/"
        XCTAssertEqual(ImportHandoff.postURL(urls: [other], texts: [text])?.absoluteString,
                       "https://www.instagram.com/p/C1a2B3c4D5e/")
    }

    func testRejectsNonInstagramAndProfileLinks() {
        XCTAssertNil(ImportHandoff.postURL(urls: [URL(string: "https://example.com/p/C1a2B3c4D5e/")!], texts: []))
        XCTAssertNil(ImportHandoff.postURL(urls: [URL(string: "https://www.instagram.com/chef.ann/")!],
                                                    texts: ["no links here", "https://www.tiktok.com/@a/video/1"]))
        XCTAssertNil(ImportHandoff.postURL(urls: [], texts: []))
    }

    func testDeepLinkRoundTrips() {
        let link = ImportHandoff.deepLink(for: reel)
        XCTAssertEqual(link.scheme, "cookbook")
        XCTAssertEqual(link.host, "import")
        XCTAssertTrue(ImportHandoff.isImportLink(link))
        XCTAssertEqual(ImportHandoff.postURL(fromDeepLink: link), reel)
        // The query value is percent-encoded, so the post's own "/" and "?" can't leak out.
        let tracked = ImportHandoff.deepLink(for: URL(string: "https://www.instagram.com/p/C1a2B3c4D5e/?a=1&b=2")!)
        XCTAssertEqual(ImportHandoff.postURL(fromDeepLink: tracked)?.absoluteString, "https://www.instagram.com/p/C1a2B3c4D5e/")
    }

    func testRevalidatesIncomingDeepLinks() {
        // Any app or web page can open cookbook://, so the app checks the link again.
        for bad in ["cookbook://import?url=https%3A%2F%2Fevil.com%2Fp%2FC1a2B3c4D5e%2F",
                    "cookbook://import?url=https%3A%2F%2Fwww.instagram.com.evil.com%2Fp%2FC1a2B3c4D5e%2F",
                    "cookbook://import",
                    "cookbook://import?link=https%3A%2F%2Fwww.instagram.com%2Fp%2FC1a2B3c4D5e%2F",
                    "cookbook://settings?url=https%3A%2F%2Fwww.instagram.com%2Fp%2FC1a2B3c4D5e%2F",
                    "https://import?url=https%3A%2F%2Fwww.instagram.com%2Fp%2FC1a2B3c4D5e%2F"] {
            XCTAssertNil(ImportHandoff.postURL(fromDeepLink: URL(string: bad)!), bad)
        }
        XCTAssertTrue(ImportHandoff.isImportLink(URL(string: "cookbook://import?url=nope")!), "still ours: show the error")
        XCTAssertFalse(ImportHandoff.isImportLink(URL(string: "cookbook://settings")!))
    }
}
