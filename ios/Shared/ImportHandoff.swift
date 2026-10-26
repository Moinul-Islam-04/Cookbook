import Foundation

/// How the share extension hands a link to the app: it opens
/// `cookbook://import?url=<canonical Instagram or TikTok post URL>`, and the app starts the
/// usual link import. Only the link crosses over; the extension never fetches the post or
/// calls the backend. Compiled into both the app and CookbookShare.
nonisolated enum ImportHandoff {
    static let scheme = "cookbook"
    private static let host = "import"

    /// The deep link that asks the app to import `postURL` (already canonical).
    static func deepLink(for postURL: URL) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.queryItems = [URLQueryItem(name: "url", value: postURL.absoluteString)]
        return comps.url!
    }

    /// Whether `url` is meant for the app's import hand-off at all (even if its link is bad).
    static func isImportLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }

    /// The canonical post URL carried by a `cookbook://import` link, or nil.
    /// Re-validated here because any app or web page can open the `cookbook` scheme.
    static func postURL(fromDeepLink url: URL) -> URL? {
        guard isImportLink(url),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = comps.queryItems?.first(where: { $0.name == "url" })?.value else { return nil }
        return PostPlatform.post(from: value)?.url
    }

    /// The first Instagram or TikTok post among what was shared: URL items first, then any
    /// links inside shared text (both apps often share "Check out this … https://…").
    static func postURL(urls: [URL], texts: [String]) -> URL? {
        for url in urls {
            if let post = PostPlatform.post(from: url.absoluteString) { return post.url }
        }
        for text in texts {
            if let post = PostPlatform.post(from: text) { return post.url }
            for link in links(in: text) {
                if let post = PostPlatform.post(from: link.absoluteString) { return post.url }
            }
        }
        return nil
    }

    /// Whether what was shared includes a short TikTok link (vm.tiktok.com/…), so the
    /// "not supported" message can say how to get the full one.
    static func hasShortTikTokLink(urls: [URL], texts: [String]) -> Bool {
        urls.contains { TikTokLink.isShortLink($0.absoluteString) }
            || texts.contains { text in
                TikTokLink.isShortLink(text) || links(in: text).contains { TikTokLink.isShortLink($0.absoluteString) }
            }
    }

    private static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
    }
}
