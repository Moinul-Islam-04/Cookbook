import PhotosUI
import SwiftUI
import UIKit

/// A server photo with a loading placeholder and a failure placeholder (brief: "placeholder
/// on failure"). Signed URLs need no auth header, so AsyncImage can load them directly.
struct RemotePhoto: View {
    let path: String?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: path.flatMap(AppConfig.resolve)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                placeholder(systemImage: "photo.badge.exclamationmark")
            case .empty:
                if path == nil { placeholder(systemImage: "fork.knife") } else { ProgressView() }
            @unknown default:
                placeholder(systemImage: "photo")
            }
        }
    }

    private func placeholder(systemImage: String) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
    }
}

/// Turns a picked photo (often HEIC, often 12+ MP) into a JPEG of at most 2048 px on the
/// long edge before upload. The server re-encodes anyway; this keeps uploads small.
enum PhotoPreparation {
    static func jpeg(from data: Data, maxEdge: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))  // draw() applies orientation
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

/// The photo strip on the recipe screen: shows photos, adds from the library, deletes on
/// long-press (with confirmation).
struct RecipePhotosSection: View {
    let recipe: Recipe
    var onChanged: () async -> Void
    var onError: (APIError) -> Void

    @State private var picked: PhotosPickerItem?
    @State private var isUploading = false
    @State private var pendingDelete: RecipeImage?

    private let api = APIClient()

    var body: some View {
        Section {
            if !recipe.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(recipe.images) { photo in
                            RemotePhoto(path: photo.url)
                                .frame(width: recipe.images.count == 1 ? 320 : 240, height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .contextMenu {
                                    Button("Delete Photo", systemImage: "trash", role: .destructive) {
                                        pendingDelete = photo
                                    }
                                }
                                .accessibilityLabel("Recipe photo")
                                .accessibilityHint("Touch and hold for options")
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            PhotosPicker(selection: $picked, matching: .images) {
                if isUploading {
                    HStack { ProgressView(); Text("Uploading…") }
                } else {
                    Label(recipe.images.isEmpty ? "Add Photo" : "Add Another Photo", systemImage: "camera")
                }
            }
            .disabled(isUploading)
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .confirmationDialog(
            "Delete this photo?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
        ) { photo in
            Button("Delete Photo", role: .destructive) { Task { await delete(photo) } }
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        isUploading = true
        defer { isUploading = false; picked = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = PhotoPreparation.jpeg(from: data) else {
            onError(.badResponse(status: 0, detail: "Couldn't read that photo."))
            return
        }
        do {
            _ = try await api.uploadImage(recipeID: recipe.id, jpeg: jpeg)
            await onChanged()
        } catch {
            onError(error.asAPIError)
        }
    }

    private func delete(_ photo: RecipeImage) async {
        do {
            try await api.deleteImage(recipeID: recipe.id, imageID: photo.id)
            await onChanged()
        } catch {
            onError(error.asAPIError)
        }
    }
}
