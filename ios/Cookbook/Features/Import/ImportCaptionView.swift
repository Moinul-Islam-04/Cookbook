import SwiftUI

/// Paste a caption (and optionally the post link) → server draft → review screen.
/// The pasted text stays on screen through any failure, and "Enter Manually" is always
/// available, so a failed extraction never strands the user.
struct ImportCaptionView: View {
    var onSaved: (Recipe) -> Void
    var onOpenExisting: (UUID) -> Void

    /// Read the caption as soon as the screen appears (it came from the Instagram browser).
    var autoRead = false
    /// Shown above the form, e.g. why the caption couldn't be read automatically.
    var notice: String?

    @Environment(\.dismiss) private var dismiss
    @State private var caption: String
    @State private var link: String
    @State private var isReading = false
    @State private var readStarted: Date?
    @State private var readTask: Task<Void, Never>?
    @State private var error: APIError?
    @State private var linkError: String?
    @State private var draft: ImportDraft?
    @State private var manual: RecipeForm?

    private let api = APIClient()

    init(
        onSaved: @escaping (Recipe) -> Void,
        onOpenExisting: @escaping (UUID) -> Void,
        caption: String = "",
        link: String = "",
        autoRead: Bool = false,
        notice: String? = nil
    ) {
        self.onSaved = onSaved
        self.onOpenExisting = onOpenExisting
        self.autoRead = autoRead
        self.notice = notice
        _caption = State(initialValue: caption)
        _link = State(initialValue: link)
    }

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
                if isReading, let readStarted {
                    Section {
                        ReadingProgress(started: readStarted)
                    }
                }

                if let notice {
                    Section {
                        Label(notice, systemImage: "info.circle")
                            .font(.callout)
                    }
                }

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
                                .foregroundStyle(.secondary)
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
                    Text("Paste the caption, or a comment that has the recipe. Tip: in a screenshot, long-press the text to copy it (Live Text).")
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
                    // While reading, this stops the read and keeps the caption for another try.
                    if isReading {
                        Button("Stop") { readTask?.cancel() }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Read Recipe") { startReading() }
                        .disabled(caption.trimmed.isEmpty || isReading)
                }
            }
            .interactiveDismissDisabled(!caption.trimmed.isEmpty || isReading)
            .onAppear {
                if autoRead && draft == nil && readTask == nil && !caption.trimmed.isEmpty { startReading() }
            }
        }
    }

    private func startReading() {
        guard !isReading else { return }
        readTask = Task { await read() }
    }

    private func read() async {
        isReading = true
        readStarted = .now
        defer { isReading = false; readStarted = nil; readTask = nil }
        error = nil
        linkError = nil
        do {
            draft = try await api.createDraft(
                ImportDraftCreate(sourceText: caption.trimmed, sourceUrl: link.trimmed.nilIfEmpty))
        } catch is CancellationError {
            // Stopped by the user. The server may still finish; that draft just expires.
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

/// What the user sees while the server turns a caption into a draft. The local model gives
/// no progress signal, so this shows honest facts instead: what is happening, how long it
/// has taken, and how long it usually takes.
private struct ReadingProgress: View {
    let started: Date

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ProgressView()
                .controlSize(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text("Reading the recipe…")
                    .font(.headline)
                Text("Finding the ingredients and steps in the caption. This usually takes 20–60 seconds.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("\(Int(context.date.timeIntervalSince(started))) s")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
