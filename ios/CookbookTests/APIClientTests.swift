import XCTest
@testable import Cookbook

/// APIClient against a stubbed URLSession: headers, decoding and error mapping, no server.
final class APIClientTests: XCTestCase {
    private var api: APIClient!

    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        api = APIClient(baseURL: URL(string: "https://cookbook.test")!, token: "ckb_test", session: StubURLProtocol.session())
    }

    private func respond(_ status: Int, _ json: String) {
        StubURLProtocol.handler = { _ in (status, Data(json.utf8)) }
    }

    private func apiError(_ call: () async throws -> some Any, file: StaticString = #filePath, line: UInt = #line) async -> APIError? {
        do {
            _ = try await call()
            XCTFail("expected an APIError", file: file, line: line)
        } catch let error as APIError {
            return error
        } catch {
            XCTFail("expected an APIError, got \(error)", file: file, line: line)
        }
        return nil
    }

    func testSendsAuthAndIdempotencyHeadersAndSnakeCaseBody() async throws {
        respond(201, Fixtures.recipeJSON)
        var form = RecipeForm()
        form.title = "Tomato pasta"
        form.sourceUrl = "instagram.com/p/C1a2B3c4D5e"
        _ = try await api.createRecipe(form.createBody(), idempotencyKey: "key-1")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://cookbook.test/v1/recipes")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ckb_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "key-1")
        let body = String(decoding: try XCTUnwrap(StubURLProtocol.lastBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#""source_url":"instagram.com\/p\/C1a2B3c4D5e""#), body)
    }

    func testSearchQueryAndLowercasedIDs() async throws {
        respond(200, #"{"items": [], "next_cursor": null}"#)
        _ = try await api.listRecipes(search: "garlic butter", cursor: "abc", limit: 5)
        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Set(items), [URLQueryItem(name: "limit", value: "5"), URLQueryItem(name: "q", value: "garlic butter"),
                                    URLQueryItem(name: "cursor", value: "abc")])

        respond(200, Fixtures.recipeJSON)
        _ = try await api.recipe(id: Fixtures.recipeID)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/recipes/11111111-1111-1111-1111-111111111111")
    }

    func testDecodesRecipeExactly() async throws {
        respond(200, Fixtures.recipeJSON)
        let recipe = try await api.recipe(id: Fixtures.recipeID)
        XCTAssertEqual(recipe.ingredients.map(\.quantity), [nil, Decimal(string: "1.5")])
        XCTAssertEqual(recipe.ingredients[0].rawText, "salt to taste")
        XCTAssertEqual(recipe.version, 3)
    }

    func testDecodesTimestampsWithAndWithoutMicroseconds() throws {
        let recipe = try decode(Recipe.self, Fixtures.recipeJSON)
        XCTAssertEqual(recipe.createdAt.timeIntervalSince1970, 1_792_006_757.693, accuracy: 0.001)
        XCTAssertEqual(recipe.updatedAt.timeIntervalSince1970, 1_792_006_757, accuracy: 0.001)
    }

    func testFieldErrorsComeThroughTheEnvelope() async {
        respond(422, Fixtures.errorJSON(code: "validation_error",
                                        fieldErrors: #"[{"field": "ingredients.0.quantity", "message": "Must be positive"}]"#))
        let error = await apiError { try await self.api.createRecipe(RecipeForm().createBody()) }
        XCTAssertEqual(error?.fieldErrors.first?.field, "ingredients.0.quantity")
        XCTAssertEqual(error?.debugDetail, "Request ID req-123")
    }

    func testRecognizesStaleVersionAndDuplicates() async {
        respond(409, Fixtures.errorJSON(code: "stale_version", details: #"{"current_version": 4}"#))
        let stale = await apiError { try await self.api.updateRecipe(id: Fixtures.recipeID, RecipePatch(version: 3, title: "x")) }
        XCTAssertEqual(stale?.isStaleVersion, true)
        if case .server(_, let body) = stale { XCTAssertEqual(body.details?.currentVersion, 4) }

        respond(409, Fixtures.errorJSON(code: "duplicate_recipe",
                                        details: #"{"existing_recipe_id": "11111111-1111-1111-1111-111111111111", "existing_title": "Tomato pasta"}"#))
        let dup = await apiError { try await self.api.createRecipe(RecipeForm().createBody()) }
        XCTAssertEqual(dup?.duplicateOf?.id, Fixtures.recipeID)
        XCTAssertEqual(dup?.duplicateOf?.title, "Tomato pasta")
        XCTAssertEqual(dup?.isStaleVersion, false)
    }

    func testUnauthenticated() async {
        respond(401, Fixtures.errorJSON(code: "unauthenticated"))
        let error = await apiError { try await self.api.listRecipes() }
        XCTAssertEqual(error?.isUnauthenticated, true)
    }

    func testNonEnvelopeErrorIsABadResponseNotATransportError() async {
        StubURLProtocol.handler = { _ in (502, Data("<html>Bad Gateway</html>".utf8)) }
        let error = await apiError { try await self.api.listRecipes() }
        XCTAssertEqual(error, .badResponse(status: 502, detail: "No error envelope"))
    }

    func testWrongShapeIsABadResponse() async {
        respond(200, #"{"items": "nope"}"#)
        guard case .badResponse(200, _)? = await apiError({ try await self.api.listRecipes() }) else {
            return XCTFail("expected badResponse")
        }
    }

    func testNoResponseIsATransportError() async {
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let error = await apiError { try await self.api.listRecipes() }
        XCTAssertEqual(error, .transport(.cannotConnectToHost))
        XCTAssertTrue(error?.userMessage.contains("Check your internet connection") == true)
    }

    func testDeleteAccepts204() async throws {
        StubURLProtocol.handler = { _ in (204, Data()) }
        try await api.deleteRecipe(id: Fixtures.recipeID)
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "DELETE")
    }
}
