import Foundation

/// Client-side check for TikTok post links, mirroring backend/app/source_urls.py (the server
/// re-validates; this only decides whether to offer the in-app import). Compiled into both
/// the app and the CookbookShare extension (ios/Shared).
nonisolated enum TikTokLink {
    private static let hosts: Set<String> = ["tiktok.com", "www.tiktok.com", "m.tiktok.com"]
    /// Short links redirect to the post; resolving them would mean fetching TikTok.
    private static let shortHosts: Set<String> = ["vm.tiktok.com", "vt.tiktok.com"]
    private static let path = try! NSRegularExpression(
        pattern: #"^/@([A-Za-z0-9._]{1,30})/(video|photo)/([0-9]{15,22})/?$"#)

    /// The canonical post URL (`https://www.tiktok.com/@name/video/ID`) for a pasted link,
    /// or nil if it isn't a single TikTok post.
    static func postURL(from text: String) -> URL? {
        guard let comps = components(text), let host = comps.host?.lowercased(), hosts.contains(host) else {
            return nil
        }
        let p = comps.path
        guard let m = path.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)),
              let handle = Range(m.range(at: 1), in: p),
              let kind = Range(m.range(at: 2), in: p),
              let id = Range(m.range(at: 3), in: p) else { return nil }
        return URL(string: "https://www.tiktok.com/@\(p[handle])/\(p[kind])/\(p[id])")
    }

    static let shortLinkAdvice = "Cookbook can't open short TikTok links (vm.tiktok.com/…). Open the post on tiktok.com and copy its full link (…/@name/video/…)."

    /// A vm./vt.tiktok.com or tiktok.com/t/… link, which the app can't use as is.
    static func isShortLink(_ text: String) -> Bool {
        guard let comps = components(text), let host = comps.host?.lowercased() else { return false }
        return shortHosts.contains(host) || (hosts.contains(host) && comps.path.hasPrefix("/t/"))
    }

    private static func components(_ text: String) -> URLComponents? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              comps.user == nil, comps.password == nil, comps.port == nil else { return nil }
        return comps
    }
}

/// The platforms a recipe's source link can come from.
nonisolated enum PostPlatform: Equatable {
    case instagram
    case tiktok

    var name: String {
        switch self {
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        }
    }

    /// The canonical post URL and its platform for a pasted Instagram or TikTok link.
    static func post(from text: String) -> (url: URL, platform: PostPlatform)? {
        if let url = InstagramLink.postURL(from: text) { return (url, .instagram) }
        if let url = TikTokLink.postURL(from: text) { return (url, .tiktok) }
        return nil
    }

    /// Which platform a stored source link (already canonical) belongs to, if any.
    static func of(_ link: String) -> PostPlatform? {
        post(from: link)?.platform
    }
}
