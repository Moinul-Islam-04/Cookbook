import SwiftUI
import WebKit

/// Shows a public Instagram post in a private, logged-out browser and, when the user taps
/// Import Recipe, reads the caption off the page they're looking at.
///
/// Guardrails (docs/DECISIONS.md): user-initiated only; post/reel links only; a fresh
/// non-persistent session (no cookies, never logged in, login walls are not bypassed);
/// the server never contacts Instagram, it only receives the text the user then reviews.
struct InstagramBrowserView: View {
    let url: URL
    /// The caption read from the page, and the post's link.
    var onCaption: (String, URL) -> Void
    /// The page had no readable caption; offer paste/screenshot instead.
    var onNoCaption: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var page = PageState()

    var body: some View {
        NavigationStack {
            ZStack {
                InstagramWebView(url: url, page: page)
                if page.isLoading {
                    ProgressView().controlSize(.large)
                }
            }
            .navigationTitle("Instagram")
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
                    .disabled(page.isLoading || page.isReading)
                }
            }
            .safeAreaInset(edge: .top) {
                Text("Not logged in. You're viewing Instagram's public page for this post.")
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
        let text = await page.readPageText()
        // The page the user ended up on, if they navigated to another post.
        let postURL = page.currentURL.flatMap { InstagramLink.postURL(from: $0.absoluteString) } ?? url
        if let caption = text?.caption {
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
    var isReading = false
    var currentURL: URL?
    weak var webView: WKWebView?

    func readPageText() async -> InstagramPageText? {
        guard let webView else { return nil }
        guard let json = try? await webView.evaluateJavaScript(InstagramPageText.extractionScript) as? String else {
            return nil
        }
        return try? JSONDecoder().decode(InstagramPageText.self, from: Data(json.utf8))
    }
}

private struct InstagramWebView: UIViewRepresentable {
    let url: URL
    let page: PageState

    func makeCoordinator() -> Coordinator { Coordinator(page: page) }

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
        let page: PageState
        init(page: PageState) { self.page = page }

        /// Stay on Instagram; anything else (link-in-bio sites, app-store prompts) opens in Safari.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = action.request.url, let host = target.host()?.lowercased() else {
                decisionHandler(.cancel)
                return
            }
            let instagram = host == "instagram.com" || host.hasSuffix(".instagram.com")
                || host.hasSuffix(".cdninstagram.com") || host.hasSuffix(".fbcdn.net")
            if instagram || action.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
            } else {
                if action.navigationType == .linkActivated { UIApplication.shared.open(target) }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            page.isLoading = true
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
