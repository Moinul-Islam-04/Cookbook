import SwiftUI

/// Inline failure message with the request ID (or HTTP detail) in small print, so a
/// screenshot is enough to find the matching server log line.
struct ErrorBanner: View {
    let error: APIError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.userMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            if let detail = error.debugDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Full-screen failure state with a retry action, for when there's nothing to show yet.
struct ErrorStateView: View {
    let error: APIError
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Load", systemImage: "wifi.exclamationmark")
        } description: {
            VStack(spacing: 6) {
                Text(error.userMessage)
                if let detail = error.debugDetail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } actions: {
            Button("Try Again") { Task { await retry() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

extension Error {
    /// Everything the API client throws is an APIError; anything else is a programming bug,
    /// reported as an unreadable response rather than crashing.
    var asAPIError: APIError {
        self as? APIError ?? .badResponse(status: 0, detail: String(describing: self))
    }
}
