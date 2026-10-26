import SwiftUI
import WebKit

/// Shows a public Instagram or TikTok post in a private, logged-out browser and, when the
/// user taps Import Recipe, reads the caption off the page they're looking at.
///
/// Guardrails (docs/DECISIONS.md): user-initiated only; single-post links only; a fresh
/// non-persistent session (no cookies, never logged in, login walls are not bypassed);
/// the server never contacts Instagram or TikTok, it only receives the text the user then
/// reviews.
struct PostBrowserView: View {
    let url: URL
    let platform: PostPlatform
    /// The caption read from the page, and the post's link.
    var onCaption: (String, URL) -> Void
    /// The page had no readable caption; offer paste/screenshot instead.
    var onNoCaption: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var page = PageState()

    var body: some View {
        NavigationStack {
            ZStack {
                PostWebView(url: url, platform: platform, page: page)
                if page.isLoading {
                    ProgressView().controlSize(.large)
                }
            }
            .navigationTitle(platform.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        Task { await importRecipe() }
                    } label: {
                        if page.isReading {
                            ProgressView()
                        } else {
                            Label("Import Recipe", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!page.hasContent || page.isReading)
                }
            }
            .safeAreaInset(edge: .top) {
                Text("Not logged in. You're viewing \(platform.name)'s public page for this post.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
        }
    }

    private func importRecipe() async {
        page.isReading = true
        defer { page.isReading = false }
        let caption = await page.readCaption(platform)
        // The page the user ended up on, if they navigated to another post.
        let postURL = page.currentURL.flatMap { PostPlatform.post(from: $0.absoluteString) }
            .flatMap { $0.platform == platform ? $0.url : nil } ?? url
        if let caption {
            onCaption(caption, postURL)
        } else {
            onNoCaption(postURL)
        }
    }
}

/// Bridges WKWebView state into SwiftUI.
@Observable
final class PageState {
    var isLoading = true
    /// The page has started showing. TikTok's can keep loading (video) long after its
    /// caption is on screen, so Import Recipe waits for this, not for loading to finish.
    var hasContent = false
    var isReading = false
    var currentURL: URL?
    weak var webView: WKWebView?

    /// Tries for a few seconds, since the caption may render after the page first shows.
    func readCaption(_ platform: PostPlatform) async -> String? {
        for attempt in 0..<10 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            guard let webView else { return nil }
            if let json = try? await webView.evaluateJavaScript(platform.extractionScript) as? String,
               let caption = platform.caption(fromPageJSON: json) {
                return caption
            }
        }
        return nil
    }
}

private struct PostWebView: UIViewRepresentable {
    let url: URL
    let platform: PostPlatform
    let page: PageState

    func makeCoordinator() -> Coordinator { Coordinator(platform: platform, page: page) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Fresh, in-memory session each time: no saved cookies, so never logged in.
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        page.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let platform: PostPlatform
        let page: PageState
        init(platform: PostPlatform, page: PageState) {
            self.platform = platform
            self.page = page
        }

        /// Stay on the post's site; anything else (link-in-bio sites, app-store prompts) opens in Safari.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = action.request.url, let host = target.host()?.lowercased() else {
                decisionHandler(.cancel)
                return
            }
            if platform.allowsBrowsing(host: host) || action.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
            } else {
                if action.navigationType == .linkActivated { UIApplication.shared.open(target) }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            page.isLoading = true
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            page.hasContent = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            page.isLoading = false
            page.currentURL = webView.url
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            page.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            page.isLoading = false
        }
    }
}
