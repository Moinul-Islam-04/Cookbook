import UIKit
import XCTest
@testable import Cookbook

/// The real client against the real backend (ported from the old ios/ContractTests suites).
/// Skipped unless COOKBOOK_TEST_TOKEN is set; see LiveServer. Each test creates its own
/// data with a unique tag and deletes it afterwards.
final class LiveContractTests: XCTestCase {
    private var api: APIClient!
    private var cleanup: [UUID] = []

    override func setUp() async throws {
        api = try LiveServer.client()
        cleanup = []
    }

    override func tearDown() async throws {
        for id in cleanup { try? await api.deleteRecipe(id: id) }
    }

    private func expectAPIError(_ call: () async throws -> some Any, file: StaticString = #filePath, line: UInt = #line) async -> APIError? {
        do {
            _ = try await call()
            XCTFail("expected the server to refuse", file: file, line: line)
        } catch let error as APIError {
            return error
        } catch {
            XCTFail("expected an APIError, got \(error)", file: file, line: line)
        }
        return nil
    }

    // MARK: Milestone 1: CRUD, patches, errors

    func testCreateReadPatchDelete() async throws {
        var form = RecipeForm()
        form.title = "  Contract test pasta \(uniqueTag()) "
        form.ingredients = [.init(quantity: "", unit: "", name: "salt"),
                            .init(quantity: "1 1/2", unit: "tbsp", name: "olive oil"), .init()]
        form.steps = [.init(instruction: "Boil water."), .init(instruction: "  ")]
        let created = try await api.createRecipe(form.createBody())
        cleanup.append(created.id)
        XCTAssertEqual(created.title, form.title.trimmed)
        XCTAssertEqual(created.ingredients.map(\.rawText), ["salt", "1 1/2 tbsp olive oil"])
        XCTAssertEqual(created.ingredients.map(\.quantity), [nil, Decimal(string: "1.5")])
        XCTAssertEqual(created.steps.count, 1)
        XCTAssertLessThan(abs(created.createdAt.timeIntervalSinceNow), 120)
        XCTAssertEqual(created.version, 1)

        let fetched = try await api.recipe(id: created.id)
        XCTAssertEqual(fetched, created)
        let list = try await api.listRecipes(search: created.title)
        XCTAssertTrue(list.items.contains { $0.id == created.id })

        // Title-only patch leaves the typed wording alone.
        let baseline = RecipeForm(recipe: fetched)
        var edited = baseline
        edited.title += " v2"
        let v2 = try await api.updateRecipe(id: created.id, edited.patchBody(version: fetched.version, against: baseline))
        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(v2.ingredients.map(\.rawText), ["salt", "1 1/2 tbsp olive oil"])

        // Edit one row and add notes: the server recomposes only the edited row.
        var form2 = RecipeForm(recipe: v2)
        let base2 = form2
        form2.ingredients[1].quantity = "2"
        form2.notes = "Use good oil"
        let v3 = try await api.updateRecipe(id: created.id, form2.patchBody(version: v2.version, against: base2))
        XCTAssertEqual(v3.ingredients.map(\.rawText), ["salt", "2 tbsp olive oil"])
        XCTAssertEqual(v3.notes, "Use good oil")

        // Clearing notes sends null and clears them.
        var form3 = RecipeForm(recipe: v3)
        let base3 = form3
        form3.notes = "   "
        let v4 = try await api.updateRecipe(id: created.id, form3.patchBody(version: v3.version, against: base3))
        XCTAssertNil(v4.notes)

        let stale = await expectAPIError { try await self.api.updateRecipe(id: created.id, RecipePatch(version: 1, title: "stale")) }
        XCTAssertEqual(stale?.isStaleVersion, true)
        if case .server(_, let body) = stale { XCTAssertEqual(body.details?.currentVersion, v4.version) }

        try await api.deleteRecipe(id: created.id)
        let gone = await expectAPIError { try await self.api.recipe(id: created.id) }
        guard case .server(404, let body)? = gone else { return XCTFail("expected 404, got \(String(describing: gone))") }
        XCTAssertEqual(body.code, "not_found")
    }

    func testValidationErrorPath() async {
        let body = RecipeCreate(title: "x", notes: nil, ingredients: [.init(name: "a", quantity: -1)], steps: [])
        let error = await expectAPIError { try await self.api.createRecipe(body) }
        XCTAssertEqual(error?.fieldErrors.first?.field, "ingredients.0.quantity")
    }

    func testClosedPortIsATransportError() async {
        let error = await expectAPIError { try await APIClient(baseURL: URL(string: "http://127.0.0.1:9")!).listRecipes() }
        guard case .transport? = error else { return XCTFail("expected transport, got \(String(describing: error))") }
    }

    // MARK: Milestone 2: fractions, search, links, duplicates, idempotency

    func testFractionWordingSurvivesTheServer() async throws {
        let tag = uniqueTag()
        var form = RecipeForm()
        form.title = "M2 \(tag) lemon"
        form.ingredients = [.init(quantity: "1/3", unit: "cup", name: "lemon juice"),
                            .init(quantity: "1 1/2", unit: "lb", name: "chicken")]
        let recipe = try await api.createRecipe(form.createBody(), idempotencyKey: UUID().uuidString)
        cleanup.append(recipe.id)
        XCTAssertEqual(recipe.ingredients.map(\.rawText), ["1/3 cup lemon juice", "1 1/2 lb chicken"])
        XCTAssertEqual(recipe.ingredients[0].quantity, Decimal(string: "0.333"))

        var edit = RecipeForm(recipe: recipe)
        let base = edit
        edit.ingredients[0].quantity = "1/2"
        let patched = try await api.updateRecipe(id: recipe.id, edit.patchBody(version: recipe.version, against: base))
        XCTAssertEqual(patched.ingredients.map(\.rawText), ["1/2 cup lemon juice", "1 1/2 lb chicken"])
    }

    func testSearchMatchesTitlesAndIngredientsOnce() async throws {
        let tag = uniqueTag()
        var a = RecipeForm(); a.title = "Lemon \(tag)"; a.ingredients = [.init(quantity: "2", unit: "", name: "garlic\(tag)")]
        var b = RecipeForm(); b.title = "Toast \(tag)"; b.ingredients = [.init(name: "garlic\(tag) butter"), .init(name: "GARLIC\(tag) salt")]
        let r1 = try await api.createRecipe(a.createBody()); cleanup.append(r1.id)
        let r2 = try await api.createRecipe(b.createBody()); cleanup.append(r2.id)

        let hits = try await api.listRecipes(search: "garlic\(tag)")
        XCTAssertEqual(Set(hits.items.map(\.id)), [r1.id, r2.id], "case-insensitive ingredient match, each recipe once")
        let byTitle = try await api.listRecipes(search: "toast \(tag)")
        XCTAssertEqual(byTitle.items.map(\.id), [r2.id])

        let first = try await api.listRecipes(search: "garlic\(tag)", limit: 1)
        let cursor = try XCTUnwrap(first.nextCursor)
        let reused = await expectAPIError { try await self.api.listRecipes(search: "other", cursor: cursor) }
        XCTAssertEqual(reused?.fieldErrors.first?.field, "cursor", "a cursor only continues its own search")
        let second = try await api.listRecipes(search: "garlic\(tag)", cursor: cursor, limit: 1)
        XCTAssertEqual(second.items.count, 1)
        XCTAssertNotEqual(second.items.first?.id, first.items.first?.id)
    }

    func testSourceLinksAndDuplicates() async throws {
        let tag = uniqueTag(), code = uniqueShortcode("Zz")
        var s1 = RecipeForm(); s1.title = "Reel \(tag)"; s1.sourceUrl = "https://www.instagram.com/reel/\(code)/?igsh=xyz"
        let r3 = try await api.createRecipe(s1.createBody(), idempotencyKey: UUID().uuidString); cleanup.append(r3.id)
        XCTAssertEqual(r3.sourceUrl, "https://www.instagram.com/reel/\(code)/", "tracking stripped")

        var s2 = RecipeForm(); s2.title = "Same reel \(tag)"; s2.sourceUrl = "instagram.com/p/\(code)"
        let dup = await expectAPIError { try await self.api.createRecipe(s2.createBody(), idempotencyKey: UUID().uuidString) }
        XCTAssertEqual(dup?.duplicateOf?.id, r3.id)
        XCTAssertEqual(dup?.duplicateOf?.title, "Reel \(tag)")
        let copy = try await api.createRecipe(s2.createBody(allowDuplicate: true)); cleanup.append(copy.id)
        XCTAssertEqual(copy.sourceUrl, "https://www.instagram.com/p/\(code)/", "Save Anyway creates a copy")

        var bad = RecipeForm(); bad.title = "x"; bad.sourceUrl = "https://www.tiktok.com/@a/video/1"
        let rejected = await expectAPIError { try await self.api.createRecipe(bad.createBody()) }
        XCTAssertEqual(rejected?.fieldErrors.first?.field, "source_url")

        var clear = RecipeForm(recipe: r3); let base = clear; clear.sourceUrl = "  "
        let cleared = try await api.updateRecipe(id: r3.id, clear.patchBody(version: r3.version, against: base))
        XCTAssertNil(cleared.sourceUrl)
    }

    func testIdempotentSave() async throws {
        let tag = uniqueTag(), key = UUID().uuidString
        var form = RecipeForm(); form.title = "Retry \(tag)"
        let a = try await api.createRecipe(form.createBody(), idempotencyKey: key); cleanup.append(a.id)
        let b = try await api.createRecipe(form.createBody(), idempotencyKey: key)
        XCTAssertEqual(a.id, b.id, "same key and body replays the first save")
        let saved = try await api.listRecipes(search: "Retry \(tag)")
        XCTAssertEqual(saved.items.count, 1)

        form.title += " changed"
        let reused = await expectAPIError { try await self.api.createRecipe(form.createBody(), idempotencyKey: key) }
        guard case .server(409, let body)? = reused else { return XCTFail("expected 409, got \(String(describing: reused))") }
        XCTAssertEqual(body.code, "idempotency_key_reused")
    }

    // MARK: Milestone 3: import drafts (provider-neutral: never asserts model wording)

    func testImportDraftReviewAndSave() async throws {
        let tag = uniqueTag(), code = uniqueShortcode("Mm")
        let caption = """
        Crispy Honey Garlic \(tag) 🍯

        So good!!

        Ingredients:
        - 1 1/2 lb chicken thighs
        - 3 tbsp honey
        - ½ cup soy sauce
        - salt to taste

        Method:
        1. Pat the chicken dry.
        2. Sear 5-6 minutes per side.

        #dinner
        """
        let draft = try await api.createDraft(ImportDraftCreate(sourceText: caption, sourceUrl: "instagram.com/reel/\(code)?igsh=1"))
        XCTAssertEqual(draft.status, "ready")
        XCTAssertEqual(draft.sourceUrl, "https://www.instagram.com/reel/\(code)/")
        XCTAssertEqual(draft.ingredients.map(\.rawText), ["1 1/2 lb chicken thighs", "3 tbsp honey", "½ cup soy sauce", "salt to taste"])
        XCTAssertEqual(draft.ingredients.map(\.quantity), [Decimal(string: "1.5"), 3, Decimal(string: "0.5"), nil])
        XCTAssertFalse(draft.steps.isEmpty)
        XCTAssertLessThan(abs(draft.expiresAt.timeIntervalSinceNow - 86_400), 300, "expires in about 24 h")
        let searchBeforeSave = try await api.listRecipes(search: tag)
        XCTAssertTrue(searchBeforeSave.items.isEmpty, "drafts aren't in the cookbook")

        // Review: corrections persist on the draft.
        var form = RecipeForm(draft: draft)
        form.title = "Honey Garlic Chicken \(tag)"
        form.ingredients[2].quantity = "1/3"
        form.steps.append(.init(instruction: "Glaze and serve."))
        let patched = try await api.updateDraft(id: draft.id, form.draftPatch(version: draft.version))
        XCTAssertEqual(patched.version, draft.version + 1)
        XCTAssertEqual(patched.ingredients[0].rawText, "1 1/2 lb chicken thighs")
        XCTAssertEqual(patched.ingredients[2].rawText, "1/3 cup soy sauce")
        let reread = try await api.draft(id: draft.id)
        XCTAssertEqual(reread, patched)

        // Save once; a retry with the same key replays, a new key is refused.
        let body = form.createBody(draftID: draft.id)
        let key = UUID().uuidString
        let saved = try await api.createRecipe(body, idempotencyKey: key); cleanup.append(saved.id)
        XCTAssertEqual(saved.sourceKind, "caption")
        XCTAssertEqual(saved.ingredients.map(\.rawText), ["1 1/2 lb chicken thighs", "3 tbsp honey", "1/3 cup soy sauce", "salt to taste"])
        let replay = try await api.createRecipe(body, idempotencyKey: key)
        XCTAssertEqual(replay.id, saved.id)
        let again = await expectAPIError { try await self.api.createRecipe(body, idempotencyKey: UUID().uuidString) }
        guard case .server(409, let err)? = again else { return XCTFail("expected 409, got \(String(describing: again))") }
        XCTAssertEqual(err.code, "draft_already_saved")
        XCTAssertEqual(err.details?.savedRecipeId, saved.id)
        let savedDraft = try await api.draft(id: draft.id)
        XCTAssertEqual(savedDraft.status, "saved")

        // Importing the same post again warns, and saving it still enforces the duplicate rule.
        let second = try await api.createDraft(ImportDraftCreate(sourceText: caption, sourceUrl: "https://www.instagram.com/p/\(code)/"))
        XCTAssertEqual(second.warnings.first?.code, "duplicate_post")
        XCTAssertEqual(second.warnings.first?.recipeId, saved.id)
        let dup = await expectAPIError { try await self.api.createRecipe(RecipeForm(draft: second).createBody(draftID: second.id)) }
        XCTAssertEqual(dup?.duplicateOf?.id, saved.id)
    }

    func testNonRecipeCaptionInventsNothing() async throws {
        let draft = try await api.createDraft(ImportDraftCreate(sourceText: "best beach day ever ☀️ #summer \(uniqueTag())"))
        XCTAssertEqual(draft.warnings.map(\.code), ["no_recipe_found"])
        XCTAssertTrue(draft.ingredients.isEmpty)

        let bad = await expectAPIError {
            try await self.api.createDraft(ImportDraftCreate(sourceText: "x", sourceUrl: "https://tiktok.com/@a/video/1"))
        }
        XCTAssertEqual(bad?.fieldErrors.first?.field, "source_url")
    }

    // MARK: Milestone 4: photos

    func testPhotoUploadSignedURLAndDelete() async throws {
        var form = RecipeForm(); form.title = "Photo contract \(uniqueTag())"
        let recipe = try await api.createRecipe(form.createBody()); cleanup.append(recipe.id)
        XCTAssertTrue(recipe.images.isEmpty)

        let size = CGSize(width: 3000, height: 2000)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.8))

        let image = try await api.uploadImage(recipeID: recipe.id, jpeg: jpeg)
        XCTAssertEqual(image.width, 2048, "server downsizes the long edge")
        XCTAssertEqual(image.position, 0)
        XCTAssertGreaterThan(image.urlsExpireAt, Date())

        let url = try XCTUnwrap(URL(string: image.url, relativeTo: LiveServer.baseURL)?.absoluteURL)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)  // no token
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "signed URL loads without a token")
        XCTAssertGreaterThan(data.count, 1000)
        let detail = try await api.recipe(id: recipe.id)
        XCTAssertEqual(detail.images.map(\.id), [image.id])
        let page = try await api.listRecipes(search: form.title)
        XCTAssertNotNil(page.items.first { $0.id == recipe.id }?.thumbnailUrl)

        let garbage = await expectAPIError { try await self.api.uploadImage(recipeID: recipe.id, jpeg: Data("not an image".utf8)) }
        guard case .server(422, let body)? = garbage else { return XCTFail("expected 422, got \(String(describing: garbage))") }
        XCTAssertEqual(body.code, "invalid_image")

        try await api.deleteImage(recipeID: recipe.id, imageID: image.id)
        let (_, after) = try await URLSession(configuration: .ephemeral).data(from: url)
        XCTAssertEqual((after as? HTTPURLResponse)?.statusCode, 404, "a deleted photo stops loading before its URL expires")
    }
}
