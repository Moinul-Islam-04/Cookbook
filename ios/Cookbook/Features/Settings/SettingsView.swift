import SwiftUI

/// Pair this device with the backend on your Mac, check the connection, or unpair.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = AppConfig.apiBaseURL.absoluteString
    @State private var paired = AppConfig.isPaired
    @State private var pairError: String?
    @State private var status: Status = .unknown
    @State private var confirmUnpair = false

    private enum Status: Equatable {
        case unknown, checking, ok, unreachable(String), unauthorized
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server", value: server)
                    LabeledContent("Device", value: paired ? "Paired" : "Not paired")
                    statusRow
                    Button("Check Connection") { Task { await check() } }
                        .disabled(status == .checking)
                }

                Section {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in pair(strings.first ?? "") }
                    }
                    if let pairError {
                        Text(pairError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text(paired ? "Pair Again" : "Pair This Device")
                } footer: {
                    Text("On your Mac, run `python -m app.tokens create --name \"iPhone\" --server <your Mac's address>` in the backend folder, copy the pairing code, then tap Paste here.")
                }

                if paired {
                    Section {
                        Button("Unpair This Device", role: .destructive) { confirmUnpair = true }
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

    @ViewBuilder
    private var statusRow: some View {
        switch status {
        case .unknown: EmptyView()
        case .checking: LabeledContent("Status") { ProgressView() }
        case .ok: LabeledContent("Status") { Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        case .unauthorized: LabeledContent("Status") { Label("Not signed in", systemImage: "lock.fill").foregroundStyle(.orange) }
        case .unreachable(let message):
            VStack(alignment: .leading) {
                Label("Can't reach server", systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pair(_ text: String) {
        guard let code = PairingCode(text) else {
            pairError = "That isn't a Cookbook pairing code. It starts with \"cookbook-pair:\"."
            return
        }
        pairError = nil
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
