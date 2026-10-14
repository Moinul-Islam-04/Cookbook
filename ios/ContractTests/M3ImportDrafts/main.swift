import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    print(cond ? "  ok   \(msg)" : "  FAIL \(msg) (line \(line))")
    if !cond { failures += 1 }
}
let api = APIClient(token: ProcessInfo.processInfo.environment["TOKEN"])
let tag = String(UUID().uuidString.prefix(6))
let code = "Mm" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9))
var cleanup: [UUID] = []

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

print("Create draft")
let d = try await api.createDraft(ImportDraftCreate(sourceText: caption, sourceUrl: "instagram.com/reel/\(code)?igsh=1"))
// Model-dependent: only assert what any provider must do (brief: never assert live wording).
check(d.status == "ready" && (d.title ?? "").hasPrefix("Crispy Honey Garlic"), "title from caption: \(d.title ?? "nil")")
check(d.sourceUrl == "https://www.instagram.com/reel/\(code)/", "link normalized")
check(d.ingredients.map(\.rawText) == ["1 1/2 lb chicken thighs", "3 tbsp honey", "½ cup soy sauce", "salt to taste"], "raw lines kept")
check(d.ingredients.map(\.quantity) == [Decimal(string: "1.5"), 3, Decimal(string: "0.5"), nil], "quantities decoded exactly")
check(!d.steps.isEmpty && !d.warnings.contains { $0.code == "no_recipe_found" }, "steps found (\(d.steps.count)), recipe recognized")
check(abs(d.expiresAt.timeIntervalSinceNow - 86400) < 300, "expires in ~24h")
check(try await api.listRecipes(search: tag).items.isEmpty, "draft not in cookbook search")

print("Review form round trip")
var form = RecipeForm(draft: d)
check(form.ingredients[0].quantity == "1.5" && form.ingredients[0].isUnedited, "rows load unedited")
form.title = "Honey Garlic Chicken \(tag)"
form.ingredients[2].quantity = "1/3"  // user correction
form.steps.append(.init(instruction: "Glaze and serve."))
let patched = try await api.updateDraft(id: d.id, form.draftPatch(version: d.version))
check(patched.version == d.version + 1 && patched.title == "Honey Garlic Chicken \(tag)", "corrections persisted")
check(patched.ingredients[0].rawText == "1 1/2 lb chicken thighs" && patched.ingredients[2].rawText == "1/3 cup soy sauce",
      "untouched row keeps wording, edited row keeps typed fraction: \(patched.ingredients.map(\.rawText))")
check(patched.steps.count == d.steps.count + 1, "added step persisted")
let reread = try await api.draft(id: d.id)
check(reread == patched, "GET returns the corrected draft")

print("Validation")
var empty = RecipeForm(draft: d); empty.steps = [.init()]
check(empty.validationErrors(reviewedImport: true)["steps"] != nil, "review requires a step (client)")
check(empty.validationErrors(reviewedImport: false)["steps"] == nil, "manual doesn't")

print("Save")
let body = form.createBody(draftID: d.id)
let key = UUID().uuidString
let saved = try await api.createRecipe(body, idempotencyKey: key); cleanup.append(saved.id)
check(saved.sourceKind == "caption" && saved.sourceUrl == d.sourceUrl, "saved as caption with link")
check(saved.ingredients.map(\.rawText) == ["1 1/2 lb chicken thighs", "3 tbsp honey", "1/3 cup soy sauce", "salt to taste"], "wording survives into recipe")
check(try await api.createRecipe(body, idempotencyKey: key).id == saved.id, "retry with key replays")
do {
    _ = try await api.createRecipe(body, idempotencyKey: UUID().uuidString)
    check(false, "second save should fail")
} catch let e as APIError {
    if case .server(409, let b) = e { check(b.code == "draft_already_saved" && b.details?.savedRecipeId == saved.id, "draft saves once (409 with saved id)") }
    else { check(false, "expected 409 got \(e)") }
}
check(try await api.draft(id: d.id).status == "saved", "draft marked saved")
check(try await api.listRecipes(search: "chicken thighs").items.contains { $0.id == saved.id }, "now searchable by ingredient")

print("Duplicate + non-recipe + errors")
let d2 = try await api.createDraft(ImportDraftCreate(sourceText: caption, sourceUrl: "https://www.instagram.com/p/\(code)/"))
check(d2.warnings.first?.code == "duplicate_post" && d2.warnings.first?.recipeId == saved.id, "duplicate_post warning on draft")
do {
    _ = try await api.createRecipe(RecipeForm(draft: d2).createBody(draftID: d2.id))
    check(false, "duplicate save should 409")
} catch let e as APIError {
    check(e.duplicateOf?.id == saved.id, "save still enforces duplicate rule")
}
let chatter = try await api.createDraft(ImportDraftCreate(sourceText: "best beach day ever ☀️ #summer \(tag)"))
check(chatter.warnings.map(\.code) == ["no_recipe_found"] && chatter.ingredients.isEmpty, "non-recipe → no_recipe_found, nothing invented")
check(RecipeForm(draft: chatter).ingredients.count == 1 && RecipeForm(draft: chatter).ingredients[0].isBlank, "empty draft gives one blank row to fill")
do {
    _ = try await api.createDraft(ImportDraftCreate(sourceText: "x", sourceUrl: "https://tiktok.com/@a/video/1"))
    check(false, "tiktok should fail")
} catch let e as APIError {
    check(e.fieldErrors.first?.field == "source_url", "bad link → source_url field error")
}

for id in cleanup { try? await api.deleteRecipe(id: id) }
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
