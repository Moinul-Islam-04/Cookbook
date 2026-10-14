import SwiftUI

/// Create or edit a recipe. Unsaved text is never thrown away by a failed save: errors are
/// shown inline and the form stays as the user left it.
struct RecipeEditorView: View {
    enum Mode {
        case create
        case edit(Recipe)
    }

    let mode: Mode
    var onSaved: (Recipe) -> Void
    /// Called with the existing recipe's ID when the user picks "Open Existing" on a
    /// duplicate-post warning. The editor dismisses itself first.
    var onOpenExisting: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var form: RecipeForm
    /// The form as loaded, used to send only changed fields and to detect unsaved edits.
    @State private var baseline: RecipeForm
    @State private var version: Int?
    @State private var isSaving = false
    @State private var saveError: APIError?
    @State private var fieldErrors: [String: String] = [:]
    @State private var showStaleVersion = false
    @State private var confirmDiscard = false
    @State private var duplicate: Duplicate?
    /// The last create attempt. A retry of the identical body reuses its Idempotency-Key, so
    /// a save whose response was lost isn't stored twice; any edit gets a fresh key.
    @State private var lastAttempt: (body: RecipeCreate, key: String)?

    private struct Duplicate {
        let id: UUID
        let title: String
    }

    private let api = APIClient()

    init(mode: Mode, onSaved: @escaping (Recipe) -> Void, onOpenExisting: ((UUID) -> Void)? = nil) {
        self.mode = mode
        self.onSaved = onSaved
        self.onOpenExisting = onOpenExisting
        let initial: RecipeForm
        switch mode {
        case .create:
            initial = RecipeForm()
            _version = State(initialValue: nil)
        case .edit(let recipe):
            initial = RecipeForm(recipe: recipe)
            _version = State(initialValue: recipe.version)
        }
        _form = State(initialValue: initial)
        _baseline = State(initialValue: initial)
    }

    private var hasChanges: Bool { form != baseline }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError {
                    Section {
                        ErrorBanner(error: saveError)
                    }
                }

                Section("Title") {
                    TextField("e.g. Weeknight tomato pasta", text: $form.title)
                        .textInputAutocapitalization(.words)
                    FieldErrorText(fieldErrors["title"])
                }

                ingredientsSection
                stepsSection

                Section {
                    TextField("instagram.com/reel/…", text: $form.sourceUrl)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Instagram link")
                    FieldErrorText(fieldErrors["source_url"])
                } header: {
                    Text("Source")
                } footer: {
                    Text("Optional. Paste the post or reel link so you can find the original and avoid saving it twice.")
                }

                Section("Notes") {
                    TextField("Optional", text: $form.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(isCreating ? "New Recipe" : "Edit Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(isCreating ? false : !hasChanges)
                    }
                }
            }
            // A swipe-down shouldn't silently discard typing.
            .interactiveDismissDisabled(hasChanges || isSaving)
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .alert("This recipe changed somewhere else", isPresented: $showStaleVersion) {
                Button("Save My Version") { Task { await overwriteStale() } }
                Button("Discard Mine and Reload", role: .destructive) { Task { await reloadDiscarding() } }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your edits are still here. Save them over the newer version, or discard them and load the latest.")
            }
            .alert(
                "Already in your cookbook",
                isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }),
                presenting: duplicate
            ) { dup in
                if let onOpenExisting {
                    Button("Open Existing") {
                        dismiss()
                        onOpenExisting(dup.id)
                    }
                }
                Button("Save Anyway") { Task { await save(allowDuplicate: true) } }
                Button("Keep Editing", role: .cancel) {}
            } message: { dup in
                Text(dup.title.isEmpty
                     ? "You've already saved a recipe from this post."
                     : "You saved this post as \u{201C}\(dup.title)\u{201D}. Save another copy anyway?")
            }
        }
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    private var recipeID: UUID? {
        if case .edit(let recipe) = mode { return recipe.id }
        return nil
    }

    // MARK: Sections

    private var ingredientsSection: some View {
        Section {
            ForEach($form.ingredients) { $row in
                let index = sentIndex(of: row.id)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Qty", text: $row.quantity)
                            .keyboardType(.numbersAndPunctuation)
                            .frame(maxWidth: 56)
                            .accessibilityLabel("Quantity")
                        TextField("Unit", text: $row.unit)
                            .textInputAutocapitalization(.never)
                            .frame(maxWidth: 72)
                            .accessibilityLabel("Unit")
                        TextField("Ingredient", text: $row.name)
                            .accessibilityLabel("Ingredient name")
                    }
                    if let index {
                        FieldErrorText(fieldErrors["ingredients.\(index).name"])
                        FieldErrorText(fieldErrors["ingredients.\(index).quantity"])
                    }
                }
            }
            .onDelete { form.ingredients.remove(atOffsets: $0) }
            .onMove { form.ingredients.move(fromOffsets: $0, toOffset: $1) }

            Button {
                form.ingredients.append(.init())
            } label: {
                Label("Add Ingredient", systemImage: "plus")
            }
        } header: {
            HStack {
                Text("Ingredients")
                Spacer()
                EditButton().font(.caption).textCase(nil)
            }
        } footer: {
            Text("Leave quantity empty for things like \"salt to taste\".")
        }
    }

    private var stepsSection: some View {
        Section("Steps") {
            ForEach(Array($form.steps.enumerated()), id: \.element.id) { offset, $step in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(offset + 1).")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    TextField("Describe this step", text: $step.instruction, axis: .vertical)
                        .lineLimit(1...6)
                        .accessibilityLabel("Step \(offset + 1)")
                }
            }
            .onDelete { form.steps.remove(atOffsets: $0) }
            .onMove { form.steps.move(fromOffsets: $0, toOffset: $1) }

            Button {
                form.steps.append(.init())
            } label: {
                Label("Add Step", systemImage: "plus")
            }
        }
    }

    /// Server and validation errors index into the rows actually sent, which skip blank rows.
    private func sentIndex(of rowID: UUID) -> Int? {
        form.ingredients.filter { !$0.isBlank }.firstIndex { $0.id == rowID }
    }

    // MARK: Saving

    private func save(allowDuplicate: Bool = false) async {
        guard !isSaving else { return }
        saveError = nil
        fieldErrors = form.validationErrors
        guard fieldErrors.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }
        do {
            let saved: Recipe
            if let recipeID, let version {
                saved = try await api.updateRecipe(
                    id: recipeID,
                    form.patchBody(version: version, against: baseline, allowDuplicate: allowDuplicate))
            } else {
                let body = form.createBody(allowDuplicate: allowDuplicate)
                let key = lastAttempt?.body == body ? lastAttempt!.key : UUID().uuidString
                lastAttempt = (body, key)
                saved = try await api.createRecipe(body, idempotencyKey: key)
            }
            onSaved(saved)
            dismiss()
        } catch let error as APIError {
            handle(error)
        } catch {
            saveError = .badResponse(status: 0, detail: String(describing: error))
        }
    }

    private func handle(_ error: APIError) {
        if error.isStaleVersion {
            showStaleVersion = true
            return
        }
        if let dup = error.duplicateOf {
            duplicate = Duplicate(id: dup.id, title: dup.title)
            return
        }
        fieldErrors = Dictionary(error.fieldErrors.map { ($0.field, $0.message) }, uniquingKeysWith: { a, _ in a })
        saveError = error
    }

    /// Keep the user's form, but diff it against the latest server copy and use its version.
    private func overwriteStale() async {
        guard let recipeID else { return }
        do {
            let latest = try await api.recipe(id: recipeID)
            baseline = RecipeForm(recipe: latest)
            version = latest.version
            await save()
        } catch let error as APIError {
            saveError = error
        } catch {}
    }

    private func reloadDiscarding() async {
        guard let recipeID else { return }
        do {
            let latest = try await api.recipe(id: recipeID)
            form = RecipeForm(recipe: latest)
            baseline = form
            version = latest.version
            fieldErrors = [:]
            saveError = nil
            onSaved(latest)
        } catch let error as APIError {
            saveError = error
        } catch {}
    }
}

private struct FieldErrorText: View {
    let message: String?
    init(_ message: String?) { self.message = message }

    var body: some View {
        if let message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
