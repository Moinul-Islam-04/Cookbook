import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    print(cond ? "  ok   \(msg)" : "  FAIL \(msg) (line \(line))")
    if !cond { failures += 1 }
}
let api = APIClient(token: ProcessInfo.processInfo.environment["TOKEN"])

// 1. Quantity parsing
print("QuantityText")
check(QuantityText.parse("2") == 2, "2")
check(QuantityText.parse("1.5") == Decimal(string: "1.5"), "1.5")
check(QuantityText.parse("1 1/2") == Decimal(string: "1.5"), "1 1/2")
check(QuantityText.parse("1/3") == Decimal(string: "0.333"), "1/3 rounds to 0.333")
check(QuantityText.parse("0") == nil, "0 rejected")
check(QuantityText.parse("2abc") == nil, "2abc rejected")
check(QuantityText.parse("1/0") == nil, "1/0 rejected")
check(QuantityText.parse("/2") == nil, "/2 rejected")

// 2. Live server round trip through the real client
print("Create → read → list")
var form = RecipeForm()
form.title = "  Contract test pasta "
form.ingredients = [
    .init(quantity: "", unit: "", name: "salt"),
    .init(quantity: "1 1/2", unit: "tbsp", name: "olive oil"),
    .init(), // blank row, must be dropped
]
form.steps = [.init(instruction: "Boil water."), .init(instruction: "  ")]
check(form.validationErrors.isEmpty, "valid form has no errors")
let created = try await api.createRecipe(form.createBody())
check(created.title == "Contract test pasta", "title trimmed")
check(created.ingredients.count == 2, "blank ingredient row dropped")
check(created.ingredients[0].quantity == nil && created.ingredients[0].rawText == "salt", "unmeasured stays null")
check(created.ingredients[1].quantity == Decimal(string: "1.5"), "quantity 1.5 decodes exactly")
check(created.steps.count == 1, "blank step dropped")
check(abs(created.createdAt.timeIntervalSinceNow) < 120, "createdAt decoded to a sane date (\(created.createdAt))")
check(created.version == 1, "version 1")

let fetched = try await api.recipe(id: created.id)
check(fetched == created, "GET matches POST response")
let page = try await api.listRecipes()
check(page.items.contains { $0.id == created.id }, "appears in list")

// 3. PATCH sends only changes; raw_text preserved on untouched rows
print("Patch")
let baseline = RecipeForm(recipe: fetched)
var edited = baseline
edited.title = "Contract test pasta v2"
let titleOnly = edited.patchBody(version: fetched.version, against: baseline)
check(titleOnly.ingredients == nil && titleOnly.steps == nil && titleOnly.notes == nil, "title-only edit sends only title")
let json = String(decoding: try APIClient.encoder.encode(titleOnly), as: UTF8.self)
check(!json.contains("notes"), "untouched notes key omitted: \(json)")
let v2 = try await api.updateRecipe(id: created.id, titleOnly)
check(v2.version == 2 && v2.title == "Contract test pasta v2", "patch applied, version 2")
check(v2.ingredients.map(\.rawText) == ["salt", "1 1/2 tbsp olive oil"], "ingredients untouched (typed wording kept)")

// Edit one ingredient: edited row's raw_text recomposed, untouched row keeps wording
var form2 = RecipeForm(recipe: v2)
let base2 = form2
form2.ingredients[1].quantity = "2"
form2.notes = "Use good oil"
let p2 = form2.patchBody(version: v2.version, against: base2)
check(p2.ingredients?[0].rawText == "salt", "untouched row sends original raw_text")
check(p2.ingredients?[1].rawText == nil, "edited row drops raw_text")
let v3 = try await api.updateRecipe(id: created.id, p2)
check(v3.ingredients[1].rawText == "2 tbsp olive oil", "server recomposed edited row")
check(v3.notes == "Use good oil", "notes set")

// Clearing notes must send explicit null
var form3 = RecipeForm(recipe: v3)
let base3 = form3
form3.notes = "   "
let p3 = form3.patchBody(version: v3.version, against: base3)
let json3 = String(decoding: try APIClient.encoder.encode(p3), as: UTF8.self)
check(json3.contains("\"notes\":null"), "clearing notes sends null: \(json3)")
let v4 = try await api.updateRecipe(id: created.id, p3)
check(v4.notes == nil, "notes cleared on server")

// 4. Errors
print("Errors")
do {
    _ = try await api.updateRecipe(id: created.id, RecipePatch(version: 1, title: "stale"))
    check(false, "stale version should throw")
} catch let e as APIError {
    check(e.isStaleVersion, "409 stale_version recognized")
    if case .server(_, let body) = e { check(body.details?.currentVersion == v4.version, "current_version = \(v4.version)") }
}
do {
    _ = try await api.createRecipe(RecipeCreate(title: "x", notes: nil, ingredients: [.init(name: "a", quantity: -1)], steps: []))
    check(false, "negative quantity should throw")
} catch let e as APIError {
    check(e.fieldErrors.first?.field == "ingredients.0.quantity", "422 field error path: \(e.fieldErrors.map(\.field))")
}

// 5. Delete
print("Delete")
try await api.deleteRecipe(id: created.id)
do {
    _ = try await api.recipe(id: created.id)
    check(false, "deleted recipe should 404")
} catch let e as APIError {
    if case .server(404, let body) = e { check(body.code == "not_found", "404 not_found after delete") } else { check(false, "expected 404, got \(e)") }
}

// 6. Server down → transport error, not a decoding error
print("Transport")
do {
    _ = try await APIClient(baseURL: URL(string: "http://127.0.0.1:9")!).listRecipes()
    check(false, "should fail")
} catch let e as APIError {
    if case .transport = e { check(true, "closed port → .transport") } else { check(false, "expected transport, got \(e)") }
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
