import SwiftUI

/// Instagram or TikTok link → in-app browser → caption → Import Caption (auto-reads) →
/// review → save. If the page shows no caption (login wall, video-only post), the import
/// screen opens with the link filled in and asks for the caption instead.
struct LinkImportFlow: View {
    let url: URL
    let platform: PostPlatform
    var onSaved: (Recipe) -> Void
    var onOpenExisting: (UUID) -> Void

    @State private var stage: Stage = .browsing

    private enum Stage {
        case browsing
        case caption(String, URL)
        case noCaption(URL)
    }

    var body: some View {
        switch stage {
        case .browsing:
            PostBrowserView(
                url: url, platform: platform,
                onCaption: { caption, link in stage = .caption(caption, link) },
                onNoCaption: { link in stage = .noCaption(link) })
        case .caption(let caption, let link):
            ImportCaptionView(
                onSaved: onSaved, onOpenExisting: onOpenExisting,
                caption: caption, link: link.absoluteString, autoRead: true)
        case .noCaption(let link):
            ImportCaptionView(
                onSaved: onSaved, onOpenExisting: onOpenExisting,
                link: link.absoluteString,
                notice: "\(platform.name) didn't show a caption for this post (it may need a login, or the recipe is only in the video). Paste the caption or a comment with the recipe below.")
        }
    }
}

/// Lets `.sheet(item:)` present the flow for a URL.
struct LinkImportRequest: Identifiable {
    let url: URL
    let platform: PostPlatform
    var id: String { url.absoluteString }
}
