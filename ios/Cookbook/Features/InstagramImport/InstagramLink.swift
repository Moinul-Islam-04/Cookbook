import Foundation

/// Client-side check for Instagram post/reel links, mirroring backend/app/source_urls.py
/// (the server re-validates; this only decides whether to offer the in-app import).
nonisolated enum InstagramLink {
    private static let hosts: Set<String> = ["instagram.com", "www.instagram.com", "m.instagram.com"]
    private static let path = try! NSRegularExpression(
        pattern: #"^/(?:[A-Za-z0-9._]{1,30}/)?(p|reel|reels|tv)/([A-Za-z0-9_-]{5,64})/?$"#)

    /// The canonical post URL for a pasted link, or nil if it isn't a single post or reel.
    static func postURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = comps.host?.lowercased(), hosts.contains(host),
              comps.user == nil, comps.password == nil, comps.port == nil else { return nil }
        let p = comps.path
        guard let m = path.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)),
              let kindRange = Range(m.range(at: 1), in: p),
              let codeRange = Range(m.range(at: 2), in: p) else { return nil }
        let kind = ["reel", "reels"].contains(String(p[kindRange])) ? "reel" : "p"
        return URL(string: "https://www.instagram.com/\(kind)/\(p[codeRange])/")
    }
}

/// What the in-app browser read off a public Instagram post page.
nonisolated struct InstagramPageText: Decodable, Equatable {
    /// Longest visible <h1>: logged-out post pages render the caption there.
    var heading: String?
    /// og:description, typically `123 likes, 4 comments - user on May 1, 2026: "caption"`.
    var ogDescription: String?
    /// og:title, typically `User on Instagram: "caption"`.
    var ogTitle: String?
    /// The page is showing a login form instead of the post.
    var loginWall: Bool

    /// The caption, or nil if the page didn't expose one (login wall, no caption).
    var caption: String? {
        if let heading, heading.count >= 20 { return heading }
        for candidate in [ogDescription, ogTitle].compactMap({ $0 }) {
            if let quoted = Self.quotedCaption(in: candidate) { return quoted }
        }
        return nil
    }

    /// The text inside the outermost quotes after "…: " (Instagram's meta-tag format).
    static func quotedCaption(in text: String) -> String? {
        guard let colon = text.range(of: ": \u{201C}") ?? text.range(of: ": \"") else { return nil }
        var body = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(".") { body.removeLast() }
        if body.hasSuffix("\u{201D}") || body.hasSuffix("\"") { body.removeLast() }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.count >= 10 ? body : nil
    }

    /// Runs inside the page (WKWebView). Reads only what the page already shows; no requests.
    static let extractionScript = """
    (() => {
      const meta = (p) => {
        const m = document.querySelector(`meta[property="${p}"], meta[name="${p}"]`);
        return m ? m.getAttribute('content') : null;
      };
      const headings = [...document.querySelectorAll('h1')]
        .map((e) => (e.innerText || '').trim())
        .filter((t) => t.length > 0)
        .sort((a, b) => b.length - a.length);
      return JSON.stringify({
        heading: headings[0] || null,
        ogDescription: meta('og:description'),
        ogTitle: meta('og:title'),
        loginWall: !!document.querySelector('input[name="username"], form#loginForm')
      });
    })();
    """
}
