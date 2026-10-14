import SwiftUI

/// Paste a caption (and optionally the post link) → server draft → review screen.
/// The pasted text stays on screen through any failure, and "Enter Manually" is always
/// available, so a failed extraction never strands the user.
struct ImportCaptionView: View {
    var onSaved: (Recipe) -> Void
    var onOpenExisting: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var caption = ""
    @State private var link = ""
    @State private var isReading = false
    @State private var error: APIError?
    @State private var linkError: String?
    @State private var draft: ImportDraft?
    @State private var manual: RecipeForm?

    private let api = APIClient()

    var body: some View {
        if let draft {
            RecipeEditorView(mode: .review(draft), onSaved: onSaved, onOpenExisting: onOpenExisting)
        } else if let manual {
            RecipeEditorView(mode: .createPrefilled(manual), onSaved: onSaved, onOpenExisting: onOpenExisting)
        } else {
            entryForm
        }
    }

    private var entryForm: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        ErrorBanner(error: error)
                        Button("Enter Manually Instead") { enterManually() }
                    }
                }

                Section {
                    ZStack(alignment: .topLeading) {
                        if caption.isEmpty {
                            Text("Paste the recipe caption here")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .accessibilityHidden(true)
                        }
                        TextEditor(text: $caption)
                            .frame(minHeight: 200)
                            .accessibilityLabel("Caption")
                    }
                    if UIPasteboard.general.hasStrings {
                        Button {
                            if let text = UIPasteboard.general.string { caption = text }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                    }
                } header: {
                    Text("Caption")
                } footer: {
                    Text("Copy the caption from Instagram (••• → Copy) and paste it here. The app doesn't read Instagram for you.")
                }

                Section {
                    TextField("instagram.com/reel/…", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Instagram link")
                    if let linkError {
                        Text(linkError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Link")
                } footer: {
                    Text("Optional. Saved with the recipe, and used to warn you if you've saved this post before.")
                }
            }
            .navigationTitle("Import Caption")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isReading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isReading {
                        ProgressView()
                    } else {
                        Button("Read Recipe") { Task { await read() } }
                            .disabled(caption.trimmed.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(!caption.trimmed.isEmpty || isReading)
        }
    }

    private func read() async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }
        error = nil
        linkError = nil
        do {
            draft = try await api.createDraft(
                ImportDraftCreate(sourceText: caption.trimmed, sourceUrl: link.trimmed.nilIfEmpty))
        } catch {
            let apiError = error.asAPIError
            if let field = apiError.fieldErrors.first(where: { $0.field == "source_url" }) {
                linkError = field.message
            } else {
                self.error = apiError
            }
        }
    }

    /// Start a manual recipe with the caption kept in Notes, so nothing pasted is lost.
    private func enterManually() {
        var form = RecipeForm()
        form.notes = caption.trimmed
        form.sourceUrl = link.trimmed
        manual = form
    }
}
