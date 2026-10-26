import Foundation

/// What the in-app browser read off a public TikTok post page.
///
/// Verified 2026-10-26 on a real post in the iOS 27 Simulator: the logged-out mobile page
/// shows the whole caption in `<h1 data-e2e="video-desc">` (with a "See more" button inside
/// it) and has no og:/description meta tags.
nonisolated struct TikTokPageText: Decodable, Equatable {
    /// The caption element's text, without its "See more" button.
    var description: String?

    var caption: String? {
        guard var text = description?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // In case the button's text is still attached (TikTok changes its markup).
        for label in ["See more", "See less"] {
            if text.hasPrefix(label) { text = String(text.dropFirst(label.count)) }
            if text.hasSuffix(label) { text = String(text.dropLast(label.count)) }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 10 ? text : nil
    }

    /// Runs inside the page (WKWebView). Reads only what the page already shows; no requests.
    static let extractionScript = """
    (() => {
      const desc = document.querySelector('[data-e2e="video-desc"], [data-e2e="browse-video-desc"]');
      let description = null;
      if (desc) {
        const copy = desc.cloneNode(true);
        copy.querySelectorAll('[data-e2e="video-desc-see-more"], button').forEach((e) => e.remove());
        description = (copy.textContent || '').trim() || null;
      }
      return JSON.stringify({ description });
    })();
    """
}

/// The per-platform page reading the in-app browser does on Import Recipe.
nonisolated extension PostPlatform {
    var extractionScript: String {
        switch self {
        case .instagram: InstagramPageText.extractionScript
        case .tiktok: TikTokPageText.extractionScript
        }
    }

    /// The caption from the extraction script's JSON, or nil if the page showed none.
    func caption(fromPageJSON json: String) -> String? {
        let data = Data(json.utf8)
        switch self {
        case .instagram: return (try? JSONDecoder().decode(InstagramPageText.self, from: data))?.caption
        case .tiktok: return (try? JSONDecoder().decode(TikTokPageText.self, from: data))?.caption
        }
    }

    /// Main-frame pages the in-app browser stays on; other links open in Safari.
    func allowsBrowsing(host: String) -> Bool {
        switch self {
        case .instagram:
            host == "instagram.com" || host.hasSuffix(".instagram.com")
                || host.hasSuffix(".cdninstagram.com") || host.hasSuffix(".fbcdn.net")
        case .tiktok:
            host == "tiktok.com" || host.hasSuffix(".tiktok.com")
        }
    }
}
