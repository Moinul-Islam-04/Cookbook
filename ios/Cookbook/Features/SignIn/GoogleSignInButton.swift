import AuthenticationServices
import SwiftUI
import UIKit

/// Signs in with Google and stores this device's token. Calls `onSignedIn` afterwards.
struct GoogleSignInButton: View {
    var onSignedIn: () -> Void
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            Button {
                Task { await signIn() }
            } label: {
                if working {
                    ProgressView()
                } else {
                    Label("Sign in with Google", systemImage: "person.crop.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(working)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func signIn() async {
        working = true
        errorMessage = nil
        defer { working = false }
        let pkce = GoogleSignIn.PKCE()
        let state = UUID().uuidString
        do {
            let callback = try await webAuthenticationSession.authenticate(
                using: GoogleSignIn.authorizationURL(state: state, pkce: pkce),
                callbackURLScheme: GoogleSignIn.callbackScheme,
                preferredBrowserSession: .shared
            )
            let code = try GoogleSignIn.code(from: callback, expectedState: state)
            let idToken = try await GoogleSignIn.idToken(code: code, pkce: pkce)
            let session = try await APIClient().signInWithGoogle(idToken: idToken, deviceName: UIDevice.current.name)
            AppConfig.signIn(token: session.token)
            onSignedIn()
        } catch ASWebAuthenticationSessionError.canceledLogin, GoogleSignIn.Failure.cancelled {
            // Closing the sheet isn't an error.
        } catch let failure as GoogleSignIn.Failure {
            errorMessage = failure.userMessage
        } catch is CancellationError {
        } catch {
            errorMessage = error.asAPIError.userMessage
        }
    }
}
