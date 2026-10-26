import PhotosUI
import SwiftUI

struct RecipeListView: View {
    @State private var model = RecipeListModel()
    @State private var path: [UUID] = []
    @State private var searchText = ""
    @State private var showingCreate = false
    @State private var showingImport = false
    /// + → Import from Screenshot: the picker opens here, and Import Caption opens with the
    /// picked screenshots (cancelling the picker opens nothing).
    @State private var showingScreenshotPicker = false
    @State private var pickedScreenshots: [PhotosPickerItem] = []
    @State private var screenshotImport: ScreenshotImportRequest?
    @State private var showingSettings = false
    @State private var linkImport: LinkImportRequest?
    @State private var showingLinkPrompt = false
    @State private var typedLink = ""
    @State private var clipboardHasLink = false
    /// The clipboard contents already offered (UIPasteboard.changeCount), so dismissing
    /// the banner sticks until something new is copied.
    @State private var offeredChangeCount = -1
    /// Why the last link couldn't be imported; shows the "not supported" alert.
    @State private var unsupportedLinkMessage: String?
    /// A post link handed over by the share extension (cookbook://import?url=…), waiting
    /// for the user to confirm before the browser loads anything.
    @State private var sharedLink: LinkImportRequest?
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingDelete: RecipeSummary?
    @State private var deleteError: APIError?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Cookbook")
                .searchable(text: $searchText, prompt: "Title or ingredient")
                .navigationDestination(for: UUID.self) { id in
                    RecipeDetailView(
                        recipeID: id,
                        onChanged: { Task { await model.recipeSaved() } },
                        onDeleted: { model.recipeDeleted(id: id) })
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                typedLink = ""
                                showingLinkPrompt = true
                            } label: {
                                Label("Import from Link", systemImage: "link")
                            }
                            Button {
                                showingImport = true
                            } label: {
                                Label("Import Caption", systemImage: "text.quote")
                            }
                            Button {
                                pickedScreenshots = []
                                showingScreenshotPicker = true
                            } label: {
                                Label("Import from Screenshot", systemImage: "text.viewfinder")
                            }
                            Button {
                                showingCreate = true
                            } label: {
                                Label("New Recipe", systemImage: "square.and.pencil")
                            }
                        } label: {
                            Label("Add Recipe", systemImage: "plus")
                        }
                    }
                }
                .sheet(isPresented: $showingCreate) {
                    RecipeEditorView(
                        mode: .create,
                        onSaved: { _ in Task { await model.recipeSaved() } },
                        onOpenExisting: { id in path = [id] })
                }
                .sheet(item: $linkImport) { request in
                    LinkImportFlow(
                        url: request.url, platform: request.platform,
                        onSaved: { saved in
                            Task { await model.recipeSaved() }
                            path = [saved.id]
                        },
                        onOpenExisting: { id in path = [id] })
                }
                .alert("Import from Link", isPresented: $showingLinkPrompt) {
                    TextField("Instagram or TikTok link", text: $typedLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Open") { openLink(typedLink) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Paste a link to an Instagram post or reel, or a TikTok post.")
                }
                .alert(
                    "Can't import this link",
                    isPresented: Binding(get: { unsupportedLinkMessage != nil }, set: { if !$0 { unsupportedLinkMessage = nil } }),
                    presenting: unsupportedLinkMessage
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { message in
                    Text(message)
                }
                .alert(
                    "Import from \(sharedLink?.platform.name ?? "Link")?",
                    isPresented: sharedLinkPresented, presenting: sharedLink
                ) { request in
                    Button("Open") { linkImport = request }
                    Button("Cancel", role: .cancel) {}
                } message: { request in
                    Text(request.url.absoluteString)
                }
                .onOpenURL { url in handleDeepLink(url) }
                .safeAreaInset(edge: .top) {
                    if clipboardHasLink { clipboardBanner }
                }
                .task { await checkClipboard() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await checkClipboard() } }
                }
                .sheet(isPresented: $showingSettings, onDismiss: { Task { await model.refresh() } }) {
                    SettingsView()
                }
                .sheet(isPresented: $showingImport) {
                    ImportCaptionView(
                        onSaved: { saved in
                            Task { await model.recipeSaved() }
                            path = [saved.id]
                        },
                        onOpenExisting: { id in path = [id] })
                }
                .photosPicker(
                    isPresented: $showingScreenshotPicker,
                    selection: $pickedScreenshots,
                    maxSelectionCount: 5,
                    selectionBehavior: .ordered,
                    matching: .images)
                .onChange(of: pickedScreenshots) { _, items in
                    if !items.isEmpty { screenshotImport = ScreenshotImportRequest(items: items) }
                }
                .sheet(item: $screenshotImport) { request in
                    ImportCaptionView(
                        onSaved: { saved in
                            Task { await model.recipeSaved() }
                            path = [saved.id]
                        },
                        onOpenExisting: { id in path = [id] },
                        initialScreenshots: request.items)
                }
                // Re-runs whenever the search text changes, cancelling the previous run (and
                // its in-flight request). The sleep debounces typing; a cancelled sleep throws.
                .task(id: searchText) {
                    if searchText.trimmed != model.activeSearch {
                        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    }
                    await model.refresh(search: searchText)
                }
        }
    }

    /// On a real device, an unpaired app's default 127.0.0.1 is the phone itself: ask for a
    /// pairing code instead of reporting an unreachable server. (The Simulator shares the
    /// Mac's network, so it can still reach a local dev-mode server unpaired.)
    static var needsPairing: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return !AppConfig.isPaired
        #endif
    }

    // MARK: Link import

    private var clipboardBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
            Text("You copied a link. Import it?")
                .font(.subheadline)
            Spacer()
            Button("Import") { importFromClipboard() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                offeredChangeCount = UIPasteboard.general.changeCount
                clipboardHasLink = false
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    /// Asks iOS whether the clipboard holds a web link, without reading it (no paste prompt).
    private func checkClipboard() async {
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != offeredChangeCount, pasteboard.hasURLs || pasteboard.hasStrings else {
            clipboardHasLink = false
            return
        }
        let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL])
        clipboardHasLink = patterns?.contains(\.probableWebURL) ?? false
    }

    /// Reading the clipboard happens only on this tap (iOS may ask to allow pasting).
    private func importFromClipboard() {
        let pasteboard = UIPasteboard.general
        offeredChangeCount = pasteboard.changeCount
        clipboardHasLink = false
        openLink(pasteboard.url?.absoluteString ?? pasteboard.string ?? "")
    }

    private func openLink(_ text: String) {
        if let post = PostPlatform.post(from: text) {
            linkImport = LinkImportRequest(url: post.url, platform: post.platform)
        } else {
            unsupportedLinkMessage = Self.unsupportedMessage(for: text)
        }
    }

    private static func unsupportedMessage(for text: String) -> String {
        TikTokLink.isShortLink(text)
            ? TikTokLink.shortLinkAdvice
            : "Use a link to a single Instagram post or reel (…/p/… or …/reel/…), or a TikTok post (…/@name/video/…)."
    }

    private var sharedLinkPresented: Binding<Bool> {
        Binding(get: { sharedLink != nil }, set: { if !$0 { sharedLink = nil } })
    }

    /// Share → Cookbook opens cookbook://import?url=…. Any app can open that scheme, so the
    /// link is re-validated and the user confirms before the in-app browser loads it.
    private func handleDeepLink(_ url: URL) {
        guard ImportHandoff.isImportLink(url) else { return }
        if let link = ImportHandoff.postURL(fromDeepLink: url), let post = PostPlatform.post(from: link.absoluteString) {
            sharedLink = LinkImportRequest(url: post.url, platform: post.platform)
        } else {
            unsupportedLinkMessage = Self.unsupportedMessage(for: "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading recipes…")
        case .failed(let error) where error.isUnauthenticated || Self.needsPairing:
            ContentUnavailableView {
                Label("Sign In", systemImage: "lock.iphone")
            } description: {
                Text("Sign in to see your recipes on this device.")
            } actions: {
                GoogleSignInButton { Task { await model.refresh() } }
                Button("Use a Pairing Code") { showingSettings = true }
            }
        case .failed(let error):
            ErrorStateView(error: error) { await model.refresh() }
        case .loaded where model.recipes.isEmpty && !model.activeSearch.isEmpty:
            ContentUnavailableView.search(text: model.activeSearch)
        case .loaded where model.recipes.isEmpty:
            ContentUnavailableView {
                Label("No Recipes Yet", systemImage: "book.closed")
            } description: {
                Text("Recipes you add will show up here.")
            } actions: {
                Button("Import a Caption") { showingImport = true }
                    .buttonStyle(.borderedProminent)
                Button("Add Manually") { showingCreate = true }
            }
            .refreshable { await model.refresh() }
        case .loaded:
            list
        }
    }

    private var list: some View {
        ScrollView {
            if let deleteError {
                ErrorBanner(error: deleteError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 20) {
                ForEach(model.recipes) { recipe in
                    NavigationLink(value: recipe.id) {
                        RecipeCard(recipe: recipe)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        // Not deleted here: the dialog below confirms first.
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = recipe }
                    }
                }
            }
            .padding(.horizontal)

            if model.hasMore || model.loadMoreError != nil {
                loadMoreRow
                    .padding()
            }
        }
        .refreshable { await model.refresh() }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { recipe in
            Button("Delete Recipe", role: .destructive) {
                Task {
                    do {
                        try await model.delete(id: recipe.id)
                        deleteError = nil
                    } catch {
                        deleteError = error.asAPIError
                    }
                }
            }
        } message: { _ in
            Text("This also deletes its ingredients, steps and photos. It can't be undone.")
        }
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Two columns on a phone; one at accessibility text sizes, where two would squeeze titles.
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 320 : 150), spacing: 16, alignment: .top)]
    }

    @ViewBuilder
    private var loadMoreRow: some View {
        if let error = model.loadMoreError {
            VStack(alignment: .leading) {
                ErrorBanner(error: error)
                Button("Try Again") { Task { await model.loadMore() } }
            }
        } else {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            // Fires when the spinner scrolls into view: the next page loads on demand.
            .task { await model.loadMore() }
        }
    }
}

/// A recipe in the grid: photo (or a placeholder), title, and what's in it.
private struct RecipeCard: View {
    let recipe: RecipeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if recipe.thumbnailUrl != nil {
                        RemotePhoto(path: recipe.thumbnailUrl)
                    } else {
                        RecipePlaceholder(title: recipe.title)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if recipe.sourceUrl != nil {
                        Image(systemName: "link")
                            .font(.caption.weight(.semibold))
                            .padding(7)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                    }
                }

            Text(recipe.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([recipe.title, summary, recipe.sourceUrl.flatMap(PostPlatform.of).map { "From \($0.name)" }]
            .compactMap { $0 }.joined(separator: ", "))
    }

    /// "16 ingredients · 3 steps", or what's still missing.
    private var summary: String {
        if recipe.missing.count == 2 { return "No ingredients or steps yet" }
        if recipe.missing.contains("ingredients") { return "No ingredients yet" }
        if recipe.missing.contains("steps") { return "No steps yet" }
        let ingredients = recipe.ingredientCount == 1 ? "1 ingredient" : "\(recipe.ingredientCount) ingredients"
        let steps = recipe.stepCount == 1 ? "1 step" : "\(recipe.stepCount) steps"
        return "\(ingredients) · \(steps)"
    }
}

/// Screenshots picked from + → Import from Screenshot, waiting to be read.
private struct ScreenshotImportRequest: Identifiable {
    let id = UUID()
    let items: [PhotosPickerItem]
}
