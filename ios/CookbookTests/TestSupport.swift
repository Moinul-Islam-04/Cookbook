import Foundation
import XCTest
@testable import Cookbook

/// Decodes a server-shaped JSON fixture with the app's own decoder.
func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try APIClient.decoder.decode(T.self, from: Data(json.utf8))
}

/// Encodes a request body with the app's own encoder, as the JSON string sent on the wire.
func wireJSON(_ value: some Encodable) throws -> String {
    String(decoding: try APIClient.encoder.encode(value), as: UTF8.self)
}

enum Fixtures {
    static let recipeID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    /// A recipe as GET /v1/recipes/{id} returns it.
    static let recipeJSON = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "title": "Tomato pasta",
      "notes": "Weeknight",
      "servings": 4,
      "source_kind": "manual",
      "source_url": null,
      "created_at": "2026-10-14T19:39:17.693103Z",
      "updated_at": "2026-10-14T19:39:17Z",
      "version": 3,
      "ingredients": [
        {"id": "22222222-2222-2222-2222-222222222222", "position": 0, "name": "salt",
         "quantity": null, "unit": null, "raw_text": "salt to taste"},
        {"id": "33333333-3333-3333-3333-333333333333", "position": 1, "name": "olive oil",
         "quantity": 1.5, "unit": "tbsp", "raw_text": "1 1/2 tbsp olive oil, extra virgin",
         "note": "extra virgin"}
      ],
      "steps": [{"id": "44444444-4444-4444-4444-444444444444", "position": 0, "instruction": "Cook pasta."}],
      "images": [],
      "missing": []
    }
    """

    /// An import draft whose second ingredient the server couldn't match to the caption.
    static let draftJSON = """
    {
      "id": "55555555-5555-5555-5555-555555555555",
      "status": "ready",
      "source_text": "Garlic noodles\\n- 8 oz noodles\\n- 4 cloves garlic\\n1. Boil noodles.",
      "source_url": "https://www.instagram.com/reel/C1a2B3c4D5e/",
      "title": "Garlic noodles",
      "ingredients": [
        {"name": "noodles", "quantity": 8, "unit": "oz", "raw_text": "8 oz noodles",
         "needs_review": false, "review_reasons": []},
        {"name": "garlic", "quantity": 4, "unit": "cloves", "raw_text": "4 cloves garlic, minced",
         "note": "minced", "sub_recipe": 0,
         "needs_review": true, "review_reasons": ["quantity_not_in_source"]}
      ],
      "steps": [{"instruction": "Boil noodles.", "needs_review": false, "review_reasons": []}],
      "warnings": [],
      "servings": 2,
      "sub_recipes": [{"title": "Garlic sauce"}],
      "extraction_version": "rules:1",
      "version": 1,
      "saved_recipe_id": null,
      "expires_at": "2026-10-15T19:39:17.693103Z"
    }
    """

    static func errorJSON(code: String, message: String = "Nope", fieldErrors: String = "[]",
                          details: String = "null") -> String {
        """
        {"code": "\(code)", "message": "\(message)", "field_errors": \(fieldErrors),
         "retryable": false, "request_id": "req-123", "details": \(details)}
        """
    }
}

/// Answers APIClient requests in-process, so client behavior can be tested without a server.
final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, Data)
    nonisolated(unsafe) static var handler: Handler?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // URLSession moves httpBody to a stream before the protocol sees it.
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// The live backend the contract tests run against. They're skipped unless a token is set.
/// xcodebuild passes TEST_RUNNER_-prefixed variables to the tests without the prefix:
///
///     TEST_RUNNER_COOKBOOK_TEST_TOKEN=ckb_... xcodebuild test -project ios/Cookbook.xcodeproj \
///       -scheme Cookbook -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
///
/// (or ios/run-tests.sh). In Xcode, add COOKBOOK_TEST_TOKEN under Edit Scheme → Test →
/// Arguments. The Simulator shares the Mac's network, so the default 127.0.0.1:8000 reaches
/// the launchd API; COOKBOOK_TEST_API_URL points elsewhere.
enum LiveServer {
    static var token: String? { env("COOKBOOK_TEST_TOKEN") }
    static var baseURL: URL { env("COOKBOOK_TEST_API_URL").flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:8000")! }

    static func client() throws -> APIClient {
        guard let token else {
            throw XCTSkip("Set COOKBOOK_TEST_TOKEN to run the live contract tests.")
        }
        return APIClient(baseURL: baseURL, token: token)
    }

    /// A scheme variable that wasn't provided expands to an empty string; treat that as unset.
    private static func env(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespaces)
        return (value?.isEmpty ?? true) ? nil : value
    }
}

/// Unique per run, so leftovers in the database never collide with a new run.
func uniqueTag() -> String { String(UUID().uuidString.prefix(6)) }
func uniqueShortcode(_ prefix: String) -> String {
    prefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9))
}
