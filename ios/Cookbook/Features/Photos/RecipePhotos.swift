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

/// Stands in for a recipe photo: a warm gradient with a utensil glyph. The hue varies with
/// the title, so photo-less recipes stay distinguishable in the grid.
struct RecipePlaceholder: View {
    let title: String

    var body: some View {
        let hue = Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 }) / 997
        LinearGradient(
            colors: [Color(hue: 0.02 + hue * 0.1, saturation: 0.55, brightness: 0.95),
                     Color(hue: 0.0 + hue * 0.08, saturation: 0.7, brightness: 0.8)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: "fork.knife")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .accessibilityHidden(true)
    }
}
