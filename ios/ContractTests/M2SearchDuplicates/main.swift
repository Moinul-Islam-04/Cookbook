import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    print(cond ? "  ok   \(msg)" : "  FAIL \(msg) (line \(line))")
    if !cond { failures += 1 }
}
let api = APIClient(token: ProcessInfo.processInfo.environment["TOKEN"])
let tag = String(UUID().uuidString.prefix(6))
// Shortcodes need to be unique per run so old data in the dev DB doesn't collide.
let code = "Zz" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9))
var cleanup: [UUID] = []

print("Fraction wording (Milestone 1 bug)")
var f = RecipeForm()
f.title = "M2 \(tag) lemon"
f.ingredients = [
    .init(quantity: "1/3", unit: "cup", name: "lemon juice"),
    .init(quantity: "1 1/2", unit: "lb", name: "chicken"),
    .init(quantity: "2", unit: "", name: "garlic\(tag)"),
    .init(quantity: "", unit: "", name: "salt"),
]
let r1 = try await api.createRecipe(f.createBody(), idempotencyKey: UUID().uuidString)
cleanup.append(r1.id)
check(r1.ingredients.map(\.rawText) == ["1/3 cup lemon juice", "1 1/2 lb chicken", "2 garlic\(tag)", "salt"],
      "typed wording kept: \(r1.ingredients.map(\.rawText))")
check(r1.ingredients[0].quantity == Decimal(string: "0.333"), "1/3 still stored as 0.333")
var e = RecipeForm(recipe: r1); let eb = e
e.ingredients[0].quantity = "1/2"
let pe = try await api.updateRecipe(id: r1.id, e.patchBody(version: r1.version, against: eb))
check(pe.ingredients[0].rawText == "1/2 cup lemon juice" && pe.ingredients[1].rawText == "1 1/2 lb chicken",
      "edited fraction row re-worded, untouched row kept")

print("Search")
var g = RecipeForm(); g.title = "Toast \(tag)"; g.ingredients = [.init(name: "garlic\(tag) butter"), .init(name: "GARLIC\(tag) salt")]
let r2 = try await api.createRecipe(g.createBody()); cleanup.append(r2.id)
let hits = try await api.listRecipes(search: "garlic\(tag)")
check(Set(hits.items.map(\.id)) == [r1.id, r2.id], "ingredient match, case-insensitive, each recipe once (\(hits.items.count))")
check(try await api.listRecipes(search: "toast \(tag)").items.map(\.id) == [r2.id], "title match")
let small = try await api.listRecipes(search: "garlic\(tag)", limit: 1)
check(small.nextCursor != nil, "paged search has a cursor")
do {
    _ = try await api.listRecipes(search: "other", cursor: small.nextCursor)
    check(false, "cursor reuse across searches should fail")
} catch let err as APIError {
    check(err.fieldErrors.first?.field == "cursor", "cursor bound to its search")
}
let page2 = try await api.listRecipes(search: "garlic\(tag)", cursor: small.nextCursor, limit: 1)
check(page2.items.count == 1 && page2.items[0].id != small.items[0].id, "second page continues the search")

print("Source link + duplicates")
var s1 = RecipeForm(); s1.title = "Reel \(tag)"; s1.sourceUrl = "https://www.instagram.com/reel/\(code)/?igsh=xyz"
let r3 = try await api.createRecipe(s1.createBody(), idempotencyKey: UUID().uuidString); cleanup.append(r3.id)
check(r3.sourceUrl == "https://www.instagram.com/reel/\(code)/", "link normalized: \(r3.sourceUrl ?? "nil")")
check(try await api.listRecipes(search: "Reel \(tag)").items.first?.sourceUrl == r3.sourceUrl, "list summary carries the link")
var s2 = RecipeForm(); s2.title = "Same reel \(tag)"; s2.sourceUrl = "instagram.com/p/\(code)"
do {
    _ = try await api.createRecipe(s2.createBody(), idempotencyKey: UUID().uuidString)
    check(false, "duplicate should be rejected")
} catch let err as APIError {
    check(err.duplicateOf?.id == r3.id && err.duplicateOf?.title == "Reel \(tag)", "409 duplicate decoded with existing id+title")
}
let copy = try await api.createRecipe(s2.createBody(allowDuplicate: true)); cleanup.append(copy.id)
check(copy.sourceUrl == "https://www.instagram.com/p/\(code)/", "Save Anyway creates a copy")
var bad = RecipeForm(); bad.title = "x"; bad.sourceUrl = "https://www.tiktok.com/@a/video/1"
do {
    _ = try await api.createRecipe(bad.createBody())
    check(false, "tiktok link should be rejected")
} catch let err as APIError {
    check(err.fieldErrors.first?.field == "source_url", "unsupported link → source_url field error")
}
var clr = RecipeForm(recipe: r3); let clrb = clr; clr.sourceUrl = "  "
let p3 = clr.patchBody(version: r3.version, against: clrb)
check(String(decoding: try APIClient.encoder.encode(p3), as: UTF8.self).contains("\"source_url\":null"), "clearing link sends null")
check(try await api.updateRecipe(id: r3.id, p3).sourceUrl == nil, "link cleared on server")

print("Idempotency")
var i1 = RecipeForm(); i1.title = "Retry \(tag)"
let key = UUID().uuidString
let a = try await api.createRecipe(i1.createBody(), idempotencyKey: key); cleanup.append(a.id)
let b = try await api.createRecipe(i1.createBody(), idempotencyKey: key)
check(a.id == b.id, "same key + body → same recipe")
check(try await api.listRecipes(search: "Retry \(tag)").items.count == 1, "saved once")
i1.title = "Retry \(tag) changed"
do {
    _ = try await api.createRecipe(i1.createBody(), idempotencyKey: key)
    check(false, "reused key with new body should fail")
} catch let err as APIError {
    if case .server(409, let body) = err { check(body.code == "idempotency_key_reused", "key reuse → 409 idempotency_key_reused") }
    else { check(false, "expected 409, got \(err)") }
}

for id in cleanup { try? await api.deleteRecipe(id: id) }
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
