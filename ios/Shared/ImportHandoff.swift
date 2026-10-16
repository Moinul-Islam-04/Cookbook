import Foundation

/// How the share extension hands a link to the app: it opens
/// `cookbook://import?url=<canonical Instagram post URL>`, and the app starts the usual
/// Instagram import for that link. Only the link crosses over; the extension never fetches
/// Instagram or calls the backend. Compiled into both the app and CookbookShare.
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

    /// The canonical Instagram post URL carried by a `cookbook://import` link, or nil.
    /// Re-validated here because any app or web page can open the `cookbook` scheme.
    static func postURL(fromDeepLink url: URL) -> URL? {
        guard isImportLink(url),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = comps.queryItems?.first(where: { $0.name == "url" })?.value else { return nil }
        return InstagramLink.postURL(from: value)
    }

    /// The first Instagram post or reel among what was shared: URL items first, then any
    /// links inside shared text (Instagram often shares "Check out this reel … https://…").
    static func instagramPostURL(urls: [URL], texts: [String]) -> URL? {
        for url in urls {
            if let post = InstagramLink.postURL(from: url.absoluteString) { return post }
        }
        for text in texts {
            if let post = InstagramLink.postURL(from: text) { return post }
            for link in links(in: text) {
                if let post = InstagramLink.postURL(from: link.absoluteString) { return post }
            }
        }
        return nil
    }

    private static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
    }
}
