import PhotosUI
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
    /// Screenshots picked before this screen opened (+ → Import from Screenshot): their text
    /// is read as soon as it appears.
    var initialScreenshots: [PhotosPickerItem] = []

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

    // Screenshots: text is read on the device and added to the caption for review.
    @State private var showingScreenshotPicker = false
    @State private var screenshotItems: [PhotosPickerItem] = []
    @State private var isRecognizing = false
    @State private var screenshotResult: ScreenshotResult?
    @State private var readInitialScreenshots = false

    private let api = APIClient()

    init(
        onSaved: @escaping (Recipe) -> Void,
        onOpenExisting: @escaping (UUID) -> Void,
        caption: String = "",
        link: String = "",
        autoRead: Bool = false,
        notice: String? = nil,
        initialScreenshots: [PhotosPickerItem] = []
    ) {
        self.onSaved = onSaved
        self.onOpenExisting = onOpenExisting
        self.autoRead = autoRead
        self.notice = notice
        self.initialScreenshots = initialScreenshots
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
            ScrollViewReader { scroller in
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
                        // Above the caption it describes; the form scrolls here when it changes.
                        if isRecognizing {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Reading text from the screenshots…")
                            }
                            .accessibilityElement(children: .combine)
                            .id(Self.screenshotStatusID)
                        } else if let screenshotResult {
                            ScreenshotResultLabel(result: screenshotResult)
                                .id(Self.screenshotStatusID)
                        }
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
                        Button {
                            showingScreenshotPicker = true
                        } label: {
                            Label("Read Text from Screenshots", systemImage: "text.viewfinder")
                        }
                        .disabled(isRecognizing || isReading)
                    } header: {
                        Text("Caption")
                    } footer: {
                        Text("Paste the caption, or a comment that has the recipe, or read it from screenshots of the post (pick them in order). Screenshot text is read on this iPhone and added here for you to check.")
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
                .onChange(of: isRecognizing) {
                    withAnimation { scroller.scrollTo(Self.screenshotStatusID, anchor: .top) }
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
                        .disabled(caption.trimmed.isEmpty || isReading || isRecognizing)
                }
            }
            .interactiveDismissDisabled(!caption.trimmed.isEmpty || isReading)
            .onAppear {
                if autoRead && draft == nil && readTask == nil && !caption.trimmed.isEmpty { startReading() }
                if !initialScreenshots.isEmpty && !readInitialScreenshots {
                    readInitialScreenshots = true
                    Task { await recognize(initialScreenshots) }
                }
            }
            .photosPicker(
                isPresented: $showingScreenshotPicker,
                selection: $screenshotItems,
                maxSelectionCount: 5,
                selectionBehavior: .ordered,
                matching: .images)
            .onChange(of: screenshotItems) { _, items in
                // Cancelling the picker leaves the selection empty: nothing changes.
                guard !items.isEmpty else { return }
                Task { await recognize(items) }
            }
        }
    }

    private static let screenshotStatusID = "screenshot-status"

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

    /// Reads each picked screenshot on the device, in the order picked, and adds the text
    /// after whatever is already in the caption. Nothing is sent until Read Recipe.
    private func recognize(_ items: [PhotosPickerItem]) async {
        isRecognizing = true
        screenshotResult = nil
        defer { isRecognizing = false; screenshotItems = [] }

        var pages: [String] = []
        var failed = 0
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    failed += 1
                    continue
                }
                pages.append(try await ScreenshotText.recognize(imageData: data))
            } catch {
                failed += 1
            }
        }
        let text = ScreenshotText.join(pages: pages)
        if text.trimmed.isEmpty {
            screenshotResult = failed == items.count ? .failed : .noText
        } else {
            caption = ScreenshotText.merged(existing: caption, recognized: text)
            screenshotResult = .added(
                screenshots: items.count - failed, unreadable: failed,
                checkAmounts: ScreenshotText.possibleMixedNumbers(in: text))
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

/// What the user sees while the server turns a caption into a draft. The extractor gives
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
                Text("Finding the ingredients and steps in the caption. This takes a few seconds for a short caption, and up to about 20 for a long one.")
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

/// The outcome of reading screenshots, shown above the caption.
enum ScreenshotResult: Equatable {
    case added(screenshots: Int, unreadable: Int, checkAmounts: [String])
    case noText
    case failed
}

private struct ScreenshotResultLabel: View {
    let result: ScreenshotResult

    var body: some View {
        switch result {
        case .added(let screenshots, let unreadable, let checkAmounts):
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(screenshots == 1
                         ? "Text from a screenshot was added to the caption."
                         : "Text from \(screenshots) screenshots was added to the caption.")
                        .font(.callout.weight(.semibold))
                } icon: {
                    Image(systemName: "text.viewfinder")
                }
                Text("Reading a screenshot can get words or amounts wrong. Check them, and delete anything that isn't the recipe, before you tap Read Recipe.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !checkAmounts.isEmpty {
                    Text("Check \(checkAmounts.joined(separator: ", ")) against the screenshot. A space may be missing, as in 1 1/2.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if unreadable > 0 {
                    Text(unreadable == 1
                         ? "1 screenshot couldn't be read."
                         : "\(unreadable) screenshots couldn't be read.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .accessibilityElement(children: .combine)
        case .noText:
            Label("No text was found in the screenshots. The caption wasn't changed.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        case .failed:
            Label("Couldn't read the screenshots. The caption wasn't changed. Try again, or paste the text instead.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }
}
