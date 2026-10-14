import SwiftUI

struct RecipeListView: View {
    @State private var model = RecipeListModel()
    @State private var path: [UUID] = []
    @State private var searchText = ""
    @State private var showingCreate = false
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
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingCreate = true
                        } label: {
                            Label("New Recipe", systemImage: "plus")
                        }
                    }
                }
                .sheet(isPresented: $showingCreate) {
                    RecipeEditorView(
                        mode: .create,
                        onSaved: { _ in Task { await model.recipeSaved() } },
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

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading recipes…")
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
                Button("Add a Recipe") { showingCreate = true }
                    .buttonStyle(.borderedProminent)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recipe.title)
                .font(.headline)
            HStack(spacing: 12) {
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
                Label("Missing \(recipe.missing.joined(separator: " and "))", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}
