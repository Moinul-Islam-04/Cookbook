import XCTest
@testable import Cookbook

/// The OAuth pieces of Google sign-in, without Google: PKCE, the authorization URL, the
/// redirect, the token exchange and the /v1/auth/google call against stubbed sessions.
final class GoogleSignInTests: XCTestCase {
    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
    }

    func testPKCEChallengeMatchesTheRFC7636Example() {
        let pkce = GoogleSignIn.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomVerifiersAreLongEnoughAndUnique() {
        let a = GoogleSignIn.PKCE.randomVerifier(), b = GoogleSignIn.PKCE.randomVerifier()
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.count, 43)  // RFC 7636 minimum
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testRedirectIsTheReversedClientID() {
        XCTAssertEqual(GoogleSignIn.callbackScheme, "com.googleusercontent.apps.752334209823-m3fkevjvqjjohu4qj8utvm4h211qaqfi")
        XCTAssertEqual(GoogleSignIn.redirectURI, GoogleSignIn.callbackScheme + ":/oauth2redirect")
    }

    func testAuthorizationURLAsksForACodeWithPKCE() throws {
        let pkce = GoogleSignIn.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = GoogleSignIn.authorizationURL(state: "s1", pkce: pkce)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host(), "accounts.google.com")
        XCTAssertEqual(query["client_id"], GoogleSignIn.clientID)
        XCTAssertEqual(query["redirect_uri"], GoogleSignIn.redirectURI)
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["scope"], "openid")
        XCTAssertEqual(query["state"], "s1")
        XCTAssertEqual(query["code_challenge"], pkce.challenge)
        XCTAssertEqual(query["code_challenge_method"], "S256")
    }

    func testCallbackParsing() throws {
        let base = GoogleSignIn.redirectURI
        XCTAssertEqual(try GoogleSignIn.code(from: URL(string: "\(base)?state=s1&code=4/abc")!, expectedState: "s1"), "4/abc")
        XCTAssertThrowsError(try GoogleSignIn.code(from: URL(string: "\(base)?state=other&code=4/abc")!, expectedState: "s1")) {
            XCTAssertEqual($0 as? GoogleSignIn.Failure, .badCallback)
        }
        XCTAssertThrowsError(try GoogleSignIn.code(from: URL(string: "\(base)?state=s1")!, expectedState: "s1")) {
            XCTAssertEqual($0 as? GoogleSignIn.Failure, .badCallback)
        }
        XCTAssertThrowsError(try GoogleSignIn.code(from: URL(string: "\(base)?error=access_denied&state=s1")!, expectedState: "s1")) {
            XCTAssertEqual($0 as? GoogleSignIn.Failure, .cancelled)
        }
    }

    func testTokenExchangeSendsTheVerifierAndReturnsTheIDToken() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"access_token":"a","id_token":"eyJ.id.token","expires_in":3599}"#.utf8)) }
        let pkce = GoogleSignIn.PKCE(verifier: "verifier-123")
        let token = try await GoogleSignIn.idToken(code: "4/a+b", pkce: pkce, session: StubURLProtocol.session())
        XCTAssertEqual(token, "eyJ.id.token")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url, GoogleSignIn.tokenURL)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = String(decoding: try XCTUnwrap(StubURLProtocol.lastBody), as: UTF8.self)
        XCTAssertTrue(body.contains("code=4/a%2Bb"), body)  // "+" must not become a space
        XCTAssertTrue(body.contains("code_verifier=verifier-123"))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testRefusedTokenExchangeIsReported() async {
        StubURLProtocol.handler = { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        do {
            _ = try await GoogleSignIn.idToken(code: "used", pkce: .init(), session: StubURLProtocol.session())
            XCTFail("expected a failure")
        } catch let failure as GoogleSignIn.Failure {
            guard case .tokenExchange = failure else { return XCTFail("\(failure)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testServerSignInRequestAndResponse() async throws {
        StubURLProtocol.handler = { _ in
            (201, Data(#"{"token":"ckb_new","token_id":"11111111-1111-1111-1111-111111111111","expires_at":"2027-10-18T12:00:00.123456Z"}"#.utf8))
        }
        let api = APIClient(baseURL: URL(string: "https://cookbook.test")!, token: nil, session: StubURLProtocol.session())
        let session = try await api.signInWithGoogle(idToken: "eyJ.id.token", deviceName: "iPhone")
        XCTAssertEqual(session.token, "ckb_new")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://cookbook.test/v1/auth/google")
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(StubURLProtocol.lastBody)) as? [String: String]
        XCTAssertEqual(json, ["id_token": "eyJ.id.token", "device_name": "iPhone"])
    }
}
