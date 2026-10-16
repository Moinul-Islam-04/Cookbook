import Foundation

/// Client-side check for Instagram post/reel links, mirroring backend/app/source_urls.py
/// (the server re-validates; this only decides whether to offer the in-app import).
/// Compiled into both the app and the CookbookShare extension (ios/Shared).
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
