import PhotosUI
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

    // Photos
    @State private var pickingPhoto = false
    @State private var picked: PhotosPickerItem?
    @State private var isUploading = false
    /// The photo showing in the hero pager; "Delete This Photo" acts on it.
    @State private var shownPhoto: UUID?
    @State private var pendingPhotoDelete: RecipeImage?

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
        // The title is shown large under the photo; this one names the screen in the back
        // button's history menu.
        .navigationTitle(recipe?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let recipe {
                ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                        .disabled(isDeleting)
                }
                ToolbarItem(placement: .primaryAction) {
                    moreMenu(recipe)
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
        .photosPicker(isPresented: $pickingPhoto, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Recipe", role: .destructive) { Task { await delete() } }
        } message: {
            Text("This also deletes its ingredients, steps and photos. It can't be undone.")
        }
        .confirmationDialog(
            "Delete this photo?",
            isPresented: Binding(get: { pendingPhotoDelete != nil }, set: { if !$0 { pendingPhotoDelete = nil } }),
            titleVisibility: .visible, presenting: pendingPhotoDelete
        ) { photo in
            Button("Delete Photo", role: .destructive) { Task { await deletePhoto(photo) } }
        }
        .task { await load() }
    }

    private func moreMenu(_ recipe: Recipe) -> some View {
        Menu {
            Button(recipe.images.isEmpty ? "Add Photo" : "Add Another Photo", systemImage: "camera") {
                pickingPhoto = true
            }
            .disabled(isUploading)
            if let photo = recipe.images.first(where: { $0.id == shownPhoto }) ?? recipe.images.first {
                Button("Delete This Photo", systemImage: "photo.badge.minus", role: .destructive) {
                    pendingPhotoDelete = photo
                }
            }
            Divider()
            Button("Delete Recipe", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .disabled(isDeleting)
    }

    private func content(_ recipe: Recipe) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(recipe)

                VStack(alignment: .leading, spacing: 28) {
                    if let actionError {
                        ErrorBanner(error: actionError)
                    }
                    header(recipe)
                    ingredients(recipe)
                    steps(recipe)
                    if let notes = recipe.notes {
                        section("Notes") {
                            Text(notes)
                                .textSelection(.enabled)
                        }
                    }
                    Text("Updated \(recipe.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
        }
        .refreshable { await load() }
        .solidTopEdge()
    }

    // MARK: Parts

    @ViewBuilder
    private func hero(_ recipe: Recipe) -> some View {
        Group {
            if recipe.images.isEmpty {
                Button { pickingPhoto = true } label: {
                    RecipePlaceholder(title: recipe.title)
                        .overlay(alignment: .bottom) {
                            Label("Add Photo", systemImage: "camera")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.bottom, 14)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Photo")
            } else {
                TabView(selection: $shownPhoto) {
                    ForEach(recipe.images) { photo in
                        RemotePhoto(path: photo.url)
                            .tag(Optional(photo.id))
                            .accessibilityLabel("Recipe photo")
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: recipe.images.count > 1 ? .automatic : .never))
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(recipe.images.isEmpty ? 2.2 : 4 / 3, contentMode: .fit)
        .clipped()
        .overlay {
            if isUploading {
                ZStack {
                    Rectangle().fill(.black.opacity(0.35))
                    ProgressView("Uploading…").tint(.white).foregroundStyle(.white)
                }
            }
        }
    }

    private func header(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recipe.title)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            Text(summary(recipe))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let link = recipe.sourceUrl.flatMap(URL.init(string:)) {
                Link(destination: link) {
                    Label("View on Instagram", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
    }

    private func ingredients(_ recipe: Recipe) -> some View {
        section("Ingredients") {
            if recipe.ingredients.isEmpty {
                Text("No ingredients yet").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(recipe.ingredients.enumerated()), id: \.element.id) { offset, ingredient in
                    if offset > 0 { Divider() }
                    // raw_text is the recipe's own wording, so "salt to taste" reads naturally
                    // and nothing is shown that wasn't written.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(IngredientText.emphasized(
                            rawText: ingredient.rawText, name: ingredient.name,
                            quantity: ingredient.quantity, unit: ingredient.unit))
                        if let note = IngredientText.separateNote(rawText: ingredient.rawText, note: ingredient.note) {
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func steps(_ recipe: Recipe) -> some View {
        section("Steps") {
            if recipe.steps.isEmpty {
                Text("No steps yet").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { offset, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(offset + 1)")
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(minWidth: 28, minHeight: 28)
                            .background(Circle().fill(.tint))
                        Text(step.instruction)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // VoiceOver: "Step 1: Cook pasta." rather than "1, Cook pasta."
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(offset + 1): \(step.instruction)")
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func summary(_ recipe: Recipe) -> String {
        let ingredients = recipe.ingredients.count == 1 ? "1 ingredient" : "\(recipe.ingredients.count) ingredients"
        let steps = recipe.steps.count == 1 ? "1 step" : "\(recipe.steps.count) steps"
        let parts = [recipe.servings.map { "Serves \($0)" }, ingredients, steps].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

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

    private func upload(_ item: PhotosPickerItem) async {
        isUploading = true
        defer { isUploading = false; picked = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = PhotoPreparation.jpeg(from: data) else {
            actionError = .badResponse(status: 0, detail: "Couldn't read that photo.")
            return
        }
        do {
            let photo = try await api.uploadImage(recipeID: recipeID, jpeg: jpeg)
            await load()
            shownPhoto = photo.id
            onChanged()
        } catch {
            actionError = error.asAPIError
        }
    }

    private func deletePhoto(_ photo: RecipeImage) async {
        do {
            try await api.deleteImage(recipeID: recipeID, imageID: photo.id)
            shownPhoto = nil
            await load()
            onChanged()
        } catch {
            actionError = error.asAPIError
        }
    }
}

private extension View {
    /// Dense text scrolling under the toolbar's glass buttons is hard to read with the
    /// default soft edge (iOS 26+), so this screen uses the solid one.
    @ViewBuilder
    func solidTopEdge() -> some View {
        if #available(iOS 26, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}
