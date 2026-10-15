import SwiftUI

/// Pair this device with the backend on your Mac, check the connection, or unpair.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = AppConfig.apiBaseURL.absoluteString
    @State private var paired = AppConfig.isPaired
    @State private var pairError: String?
    @State private var status: Status = .unknown
    @State private var confirmUnpair = false
    @State private var showPairing = false

    private enum Status: Equatable {
        case unknown, checking, ok, unreachable(String), unauthorized
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    statusRow
                    LabeledContent("Server") {
                        Text(server)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("Check Connection") { Task { await check() } }
                        .disabled(status == .checking)
                } header: {
                    Text("Connection")
                }

                Section {
                    if paired && !showPairing {
                        Button("Pair with a New Code") { showPairing = true }
                    } else {
                        PasteButton(payloadType: String.self) { strings in
                            Task { @MainActor in pair(strings.first ?? "") }
                        }
                        .buttonBorderShape(.capsule)
                        if let pairError {
                            Text(pairError).font(.footnote).foregroundStyle(.red)
                        }
                        DisclosureGroup("Show the command") {
                            Text("python -m app.tokens create --name \"iPhone\" --server <your Mac's address>")
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                        .font(.subheadline)
                    }
                    if paired {
                        Button("Unpair This Device", role: .destructive) { confirmUnpair = true }
                    }
                } header: {
                    Text(paired ? "Pairing" : "Pair This Device")
                } footer: {
                    if !paired || showPairing {
                        Text("Create a pairing code on your Mac (in the backend folder), copy it, then tap Paste. Paste turns on once there's text to paste.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Unpair this device?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    AppConfig.unpair()
                    refresh()
                }
            } message: {
                Text("The token is removed from this device. Your recipes stay on the server.")
            }
            .task { await check() }
        }
    }

    /// Always one row, sized to its content. As LabeledContent (iOS 27), the trailing
    /// status grew to a few hundred points tall and left a large blank gap in the section.
    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Status")
            Spacer(minLength: 12)
            Group {
                switch status {
                case .unknown, .checking:
                    ProgressView()
                case .ok:
                    StatusLabel("Connected", systemImage: "checkmark.circle.fill", color: .green)
                case .unauthorized:
                    StatusLabel("Not signed in", systemImage: "lock.fill", color: .orange)
                case .unreachable(let message):
                    VStack(alignment: .trailing, spacing: 2) {
                        StatusLabel("Can't reach server", systemImage: "wifi.exclamationmark", color: .red)
                        Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityElement(children: .combine)
    }

    private func pair(_ text: String) {
        guard let code = PairingCode(text) else {
            pairError = "That isn't a Cookbook pairing code. It starts with \"cookbook-pair:\"."
            return
        }
        pairError = nil
        showPairing = false
        AppConfig.pair(code)
        refresh()
        Task { await check() }
    }

    private func refresh() {
        server = AppConfig.apiBaseURL.absoluteString
        paired = AppConfig.isPaired
        status = .unknown
    }

    /// Reachable (/healthz), then authorized (an authenticated list call).
    private func check() async {
        status = .checking
        let api = APIClient()
        do {
            try await api.health()
            _ = try await api.listRecipes(limit: 1)
            status = .ok
        } catch {
            let apiError = error.asAPIError
            status = apiError.isUnauthenticated ? .unauthorized : .unreachable(apiError.userMessage)
        }
    }
}

/// Coloured icon, standard text: green, orange or red text on white fails WCAG contrast.
private struct StatusLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    init(_ title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
    }
}
