import SwiftUI

struct RecipeDetailView: View {
    let recipeID: UUID
    var onChanged: () -> Void
    var onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recipe: Recipe?
    @State private var loadError: APIError?
    @State private var actionError: APIError?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var isDeleting = false

    private let api = APIClient()

    var body: some View {
        Group {
            if let recipe {
                content(recipe)
            } else if let loadError {
                ErrorStateView(error: loadError) { await load() }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(recipe?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if recipe != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                        .disabled(isDeleting)
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let recipe {
                RecipeEditorView(mode: .edit(recipe)) { saved in
                    self.recipe = saved
                    onChanged()
                }
            }
        }
        .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Recipe", role: .destructive) { Task { await delete() } }
        } message: {
            Text("This also deletes its ingredients and steps. It can't be undone.")
        }
        .task { await load() }
    }

    private func content(_ recipe: Recipe) -> some View {
        List {
            if let actionError {
                ErrorBanner(error: actionError)
            }

            Section {
                Text(recipe.title)
                    .font(.title2.bold())
                    .listRowSeparator(.hidden)
            }

            RecipePhotosSection(
                recipe: recipe,
                onChanged: {
                    await load()
                    onChanged()
                },
                onError: { actionError = $0 })

            Section("Ingredients") {
                if recipe.ingredients.isEmpty {
                    Text("No ingredients yet").foregroundStyle(.secondary)
                }
                ForEach(recipe.ingredients) { ingredient in
                    // raw_text is the recipe's own wording, so "salt to taste" reads naturally
                    // and nothing is shown that wasn't written.
                    Text(ingredient.rawText)
                }
            }

            Section("Steps") {
                if recipe.steps.isEmpty {
                    Text("No steps yet").foregroundStyle(.secondary)
                }
                ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { offset, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(offset + 1).")
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(step.instruction)
                    }
                    // VoiceOver: "Step 1: Cook pasta." rather than "1., Cook pasta."
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(offset + 1): \(step.instruction)")
                }
            }

            if let link = recipe.sourceUrl.flatMap(URL.init(string:)) {
                Section("Source") {
                    Link(destination: link) {
                        Label("View on Instagram", systemImage: "arrow.up.right.square")
                    }
                }
            }

            if let notes = recipe.notes {
                Section("Notes") {
                    Text(notes)
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Label("Delete Recipe", systemImage: "trash")
                    }
                }
                .disabled(isDeleting)
            } footer: {
                Text("Updated \(recipe.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            recipe = try await api.recipe(id: recipeID)
            loadError = nil
        } catch is CancellationError {
        } catch {
            if recipe == nil { loadError = error.asAPIError } else { actionError = error.asAPIError }
        }
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await api.deleteRecipe(id: recipeID)
            onDeleted()
            dismiss()
        } catch {
            actionError = error.asAPIError
        }
    }
}
