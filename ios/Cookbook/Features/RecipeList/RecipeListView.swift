import SwiftUI

struct RecipeListView: View {
    @State private var model = RecipeListModel()
    @State private var path: [UUID] = []
    @State private var searchText = ""
    @State private var showingCreate = false
    @State private var showingImport = false
    @State private var showingSettings = false
    @State private var instagramImport: InstagramImportRequest?
    @State private var showingLinkPrompt = false
    @State private var typedLink = ""
    @State private var clipboardHasLink = false
    /// The clipboard contents already offered (UIPasteboard.changeCount), so dismissing
    /// the banner sticks until something new is copied.
    @State private var offeredChangeCount = -1
    @State private var notInstagramLink = false
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
                                Label("Import from Instagram Link", systemImage: "link")
                            }
                            Button {
                                showingImport = true
                            } label: {
                                Label("Import Caption", systemImage: "text.viewfinder")
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
                .sheet(item: $instagramImport) { request in
                    InstagramImportFlow(
                        url: request.url,
                        onSaved: { saved in
                            Task { await model.recipeSaved() }
                            path = [saved.id]
                        },
                        onOpenExisting: { id in path = [id] })
                }
                .alert("Import from Instagram", isPresented: $showingLinkPrompt) {
                    TextField("instagram.com/reel/…", text: $typedLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Open") { openInstagram(typedLink) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Paste a link to an Instagram post or reel.")
                }
                .alert("Not an Instagram post", isPresented: $notInstagramLink) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Use a link to a single Instagram post or reel (…/p/… or …/reel/…).")
                }
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

    // MARK: Instagram link import

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
        openInstagram(pasteboard.url?.absoluteString ?? pasteboard.string ?? "")
    }

    private func openInstagram(_ text: String) {
        if let url = InstagramLink.postURL(from: text) {
            instagramImport = InstagramImportRequest(url: url)
        } else {
            notInstagramLink = true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading recipes…")
        case .failed(let error) where error.isUnauthenticated || Self.needsPairing:
            ContentUnavailableView {
                Label("Pair This Device", systemImage: "lock.iphone")
            } description: {
                Text("The Cookbook server on your Mac needs a pairing code before this device can see your recipes.")
            } actions: {
                Button("Open Settings") { showingSettings = true }
                    .buttonStyle(.borderedProminent)
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
        List {
            if let deleteError {
                ErrorBanner(error: deleteError)
            }

            ForEach(model.recipes) { recipe in
                NavigationLink(value: recipe.id) {
                    RecipeRow(recipe: recipe)
                }
                .swipeActions {
                    // Not role: .destructive — that removes the row immediately, before the
                    // user confirms and before the server agrees.
                    Button("Delete", systemImage: "trash") { pendingDelete = recipe }
                        .tint(.red)
                }
            }

            if model.hasMore || model.loadMoreError != nil {
                loadMoreRow
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
            Text("This also deletes its ingredients and steps. It can't be undone.")
        }
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

private struct RecipeRow: View {
    let recipe: RecipeSummary

    @Environment(\.dynamicTypeSize) private var typeSize

    /// At accessibility text sizes, side-by-side layouts squeeze words into hyphenated
    /// columns ("in-gre-di-ents"); stack them instead.
    private var stacked: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            if recipe.thumbnailUrl != nil {
                RemotePhoto(path: recipe.thumbnailUrl)
                    .frame(width: stacked ? 120 : 56, height: stacked ? 120 : 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recipe.title)
                .font(.headline)
            (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 12))) {
                Text("^[\(recipe.ingredientCount) ingredient](inflect: true)")
                Text("^[\(recipe.stepCount) step](inflect: true)")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if recipe.sourceUrl != nil {
                Label("Instagram", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !recipe.missing.isEmpty {
                // Orange icon, secondary text: orange text on white fails WCAG contrast.
                Label {
                    Text("Missing \(recipe.missing.joined(separator: " and "))")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}
