import CryptoKit
import Foundation

/// Sign in with Google without the Google SDK: OAuth 2.0 with PKCE in the system sign-in
/// sheet (ASWebAuthenticationSession), then the ID token goes to POST /v1/auth/google,
/// which answers with an ordinary device token.
///
/// iOS OAuth clients have no secret; PKCE stops anyone who intercepts the redirect from
/// redeeming the code.
nonisolated enum GoogleSignIn {
    /// The iOS OAuth client in the Cookbook Google Cloud project. Not a secret.
    static let clientID = "752334209823-m3fkevjvqjjohu4qj8utvm4h211qaqfi.apps.googleusercontent.com"

    /// Google's redirect for iOS clients: the client ID reversed, as a URL scheme.
    static var callbackScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    static var redirectURI: String { callbackScheme + ":/oauth2redirect" }

    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    enum Failure: Error, Equatable {
        /// The user closed the sheet or declined on Google's page. Not worth an error message.
        case cancelled
        /// A redirect that isn't the answer to our request (state mismatch, no code).
        case badCallback
        /// Google's token endpoint refused the code or sent something unreadable.
        case tokenExchange(String)

        var userMessage: String {
            switch self {
            case .cancelled: return "Sign-in was cancelled."
            case .badCallback: return "Google's sign-in response didn't match this request. Try again."
            case .tokenExchange: return "Google didn't accept the sign-in. Try again."
            }
        }
    }

    /// A one-time PKCE pair: the verifier stays on the phone, the challenge goes to Google.
    struct PKCE {
        let verifier: String
        let challenge: String

        init(verifier: String = PKCE.randomVerifier()) {
            self.verifier = verifier
            challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        static func randomVerifier() -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return base64URL(Data(bytes))
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    static func authorizationURL(state: String, pkce: PKCE) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            // openid alone gives the ID token with `sub`; nothing else is needed.
            URLQueryItem(name: "scope", value: "openid"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    /// The authorization code from Google's redirect, if it answers our request.
    static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if value("error") == "access_denied" { throw Failure.cancelled }
        guard value("state") == expectedState, let code = value("code"), !code.isEmpty else {
            throw Failure.badCallback
        }
        return code
    }

    /// Redeems the code at Google's token endpoint and returns the ID token.
    static func idToken(code: String, pkce: PKCE, session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: pkce.verifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        // URLComponents leaves "+" unescaped, which a form body reads as a space.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(error.code)
        }
        struct TokenResponse: Decodable { let id_token: String }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw Failure.tokenExchange(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return body.id_token
    }
}
