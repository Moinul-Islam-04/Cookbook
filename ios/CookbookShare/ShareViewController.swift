import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share → Cookbook. Reads only the shared URL or text, checks it's an Instagram or TikTok
/// post, and opens the app with `cookbook://import?url=…` (ImportHandoff). It never fetches
/// the post or calls the backend; the app does the import the usual way.
final class ShareViewController: UIViewController {
    private let log = Logger(subsystem: "com.moinulislam.cookbook.share", category: "handoff")
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(state: state, onDone: { [weak self] in self?.finish() }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await handleSharedItems() }
    }

    private func handleSharedItems() async {
        let (urls, texts) = await sharedURLsAndTexts()
        guard let post = ImportHandoff.postURL(urls: urls, texts: texts) else {
            state.phase = ImportHandoff.hasShortTikTokLink(urls: urls, texts: texts) ? .shortTikTokLink : .unsupported
            return
        }
        state.phase = .opening(post)
        if await openApp(ImportHandoff.deepLink(for: post)) {
            finish()
        } else {
            // Couldn't switch apps: leave the link where the app's clipboard banner finds it.
            UIPasteboard.general.url = post
            state.phase = .copied(post)
        }
    }

    /// The URLs and plain text the host app shared (Safari shares a URL; Instagram often
    /// shares text with the link inside).
    private func sharedURLsAndTexts() async -> ([URL], [String]) {
        var urls: [URL] = []
        var texts: [String] = []
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty { texts.append(text) }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
                    if let url = value as? URL { urls.append(url) }
                    else if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                    else if let string = value as? String { texts.append(string) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                    if let string = value as? String { texts.append(string) }
                    else if let data = value as? Data, let string = String(data: data, encoding: .utf8) { texts.append(string) }
                }
            }
        }
        return (urls, texts)
    }

    /// Opens the containing app. Share extensions can't use `UIApplication.shared`, and
    /// `NSExtensionContext.open` is documented for Today/iMessage extensions only (it reports
    /// false here), so after trying it this asks the extension process's UIApplication, found
    /// on the responder chain, to open the URL — the approach that works on iOS 18+.
    private func openApp(_ url: URL) async -> Bool {
        if let context = extensionContext, await context.open(url) {
            log.notice("Opened Cookbook with NSExtensionContext.open")
            return true
        }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                let opened = await application.open(url)
                log.notice("UIApplication.open from the responder chain returned \(opened)")
                return opened
            }
            responder = current.next
        }
        log.error("No way to open Cookbook; copying the link instead")
        return false
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@Observable
final class ShareState {
    enum Phase: Equatable {
        case reading
        case opening(URL)
        case unsupported
        case shortTikTokLink
        case copied(URL)
    }

    var phase: Phase = .reading
}

private struct ShareView: View {
    let state: ShareState
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch state.phase {
                case .reading:
                    ProgressView()
                case .opening(let url):
                    ProgressView()
                    Text("Opening Cookbook…").font(.headline)
                    Text(url.absoluteString).font(.footnote).foregroundStyle(.secondary)
                case .unsupported:
                    ContentUnavailableView(
                        "Not an Instagram or TikTok post",
                        systemImage: "link.badge.plus",
                        description: Text("Cookbook can import a link to a single Instagram post or reel, or a TikTok post. For anything else, open Cookbook and paste the recipe text."))
                case .shortTikTokLink:
                    ContentUnavailableView(
                        "Short TikTok link",
                        systemImage: "link.badge.plus",
                        description: Text(TikTokLink.shortLinkAdvice))
                case .copied(let url):
                    ContentUnavailableView(
                        "Link copied",
                        systemImage: "doc.on.clipboard",
                        description: Text("Cookbook couldn't be opened from here. Open Cookbook and tap Import on the banner.\n\n\(url.absoluteString)"))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Cookbook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}
