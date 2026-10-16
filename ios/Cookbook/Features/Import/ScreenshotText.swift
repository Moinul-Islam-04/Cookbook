import CoreGraphics
import Foundation
import ImageIO
import UIKit
import Vision

/// Reads the text in a screenshot on the device with Apple's Vision framework. Images are
/// never uploaded for this; only the text the user then reviews goes to the server, as a
/// pasted caption would.
///
/// The text is never rewritten: lines are put in reading order and trimmed, nothing else.
/// Instagram's own labels (username, "Liked by…", "more") are left in; the extractor and
/// the review screen already deal with chatter around a recipe.
nonisolated enum ScreenshotText {
    /// One recognized line: its text and where it is in the image, in Vision's normalized
    /// coordinates (0–1, origin at the bottom left).
    struct Line: Equatable, Sendable {
        var text: String
        var box: CGRect
    }

    enum Failure: Error, Equatable {
        /// The picked item couldn't be decoded as an image.
        case unreadableImage
    }

    // MARK: Ordering and joining (pure)

    /// Joins lines in reading order: top to bottom, and left to right within a row. A
    /// vertical gap of about a line's height or more becomes a blank line, so paragraphs
    /// and sections stay apart.
    static func text(from lines: [Line]) -> String {
        let lines = lines
            .map { Line(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), box: $0.box) }
            .filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return "" }

        // Rows: lines whose vertical centers sit within half a line height of each other.
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.last?.first,
               abs(last.box.midY - line.box.midY) < min(last.box.height, line.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        let heights = lines.map(\.box.height).sorted()
        let typicalHeight = heights[heights.count / 2]

        var output: [String] = []
        var previousBottom: CGFloat?
        for row in rows {
            let ordered = row.sorted { $0.box.minX < $1.box.minX }
            let top = ordered.map(\.box.maxY).max()!
            if let previousBottom, previousBottom - top > typicalHeight * 0.9 {
                output.append("")
            }
            output.append(ordered.map(\.text).joined(separator: " "))
            previousBottom = ordered.map(\.box.minY).min()!
        }
        return output.joined(separator: "\n")
    }

    /// Joins the text of several screenshots in the order picked, one blank line apart.
    /// When a screenshot starts with the lines the previous one ended with (the user
    /// scrolled less than a screen), the repeat is dropped. Only exact repeats of at least
    /// two lines, or one long line, count, so real repeated lines are kept.
    static func join(pages: [String]) -> String {
        var result: [String] = []
        for page in pages {
            var lines = page.components(separatedBy: "\n")
            while lines.first?.ocrTrimmed.isEmpty == true { lines.removeFirst() }
            while lines.last?.ocrTrimmed.isEmpty == true { lines.removeLast() }
            guard !lines.isEmpty else { continue }

            let overlap = overlapCount(previous: result, next: lines)
            if overlap > 0 {
                lines.removeFirst(overlap)
                while lines.first?.ocrTrimmed.isEmpty == true { lines.removeFirst() }
                result += lines
            } else {
                if !result.isEmpty { result.append("") }
                result += lines
            }
        }
        return result.joined(separator: "\n")
    }

    private static func overlapCount(previous: [String], next: [String]) -> Int {
        let maxK = min(previous.count, next.count)
        guard maxK > 0 else { return 0 }
        for k in stride(from: maxK, through: 1, by: -1) {
            let tail = previous.suffix(k).map(\.ocrTrimmed)
            let head = next.prefix(k).map(\.ocrTrimmed)
            guard tail == head else { continue }
            let nonBlank = head.filter { !$0.isEmpty }
            if nonBlank.count >= 2 || (nonBlank.count == 1 && nonBlank[0].count >= 20) {
                return k
            }
        }
        return 0
    }

    /// What the caption field holds after a screenshot is read: the recognized text, added
    /// after anything already typed or pasted (which is never replaced).
    static func merged(existing: String, recognized: String) -> String {
        let recognized = recognized.ocrTrimmed
        guard !recognized.isEmpty else { return existing }
        let existingTrimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return existingTrimmed.isEmpty ? recognized : existingTrimmed + "\n\n" + recognized
    }

    /// Amounts that look like a mixed number with its space lost, such as "11/2" for
    /// "1 1/2" or "13/4" for "1 3/4". Vision in the Simulator read "1 1/2" as "11/2" in
    /// testing. These are only pointed out to the user, never changed: "11/2" could be real.
    static func possibleMixedNumbers(in text: String) -> [String] {
        // Swift regex literals have no lookbehind, so the character before is matched too.
        let pattern = /(?:^|[^\d\/.,])(([1-9])([1-9])\/([2-9]|1[0-6]))(?![\d\/])/.anchorsMatchLineEndings()
        var found: [String] = []
        for match in text.matches(of: pattern) {
            guard let digit = Int(match.output.3), let denominator = Int(match.output.4),
                  digit < denominator else { continue }
            let amount = String(match.output.1)
            if !found.contains(amount) { found.append(amount) }
        }
        return found
    }

    // MARK: Recognition (Vision, on the device)

    /// Recognizes the text in encoded image data (PNG, JPEG, HEIC). Runs off the main actor.
    @concurrent
    static func recognize(imageData: Data) async throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.unreadableImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return try await recognize(image, orientation: orientation)
    }

    @concurrent
    static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) async throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let best = observation.topCandidates(1).first else { return nil }
            return Line(text: best.string, box: observation.boundingBox)
        }
        return text(from: lines)
    }
}

private nonisolated extension String {
    var ocrTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
