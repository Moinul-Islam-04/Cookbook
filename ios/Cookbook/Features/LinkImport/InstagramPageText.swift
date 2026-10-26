import Foundation

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
