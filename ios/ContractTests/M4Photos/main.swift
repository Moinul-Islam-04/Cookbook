import Foundation
var failures = 0
func check(_ c: Bool, _ m: String, line: Int = #line) { print(c ? "  ok   \(m)" : "  FAIL \(m) (line \(line))"); if !c { failures += 1 } }
let api = APIClient(token: ProcessInfo.processInfo.environment["TOKEN"])
let jpeg = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))

print("Photos")
var f = RecipeForm(); f.title = "Photo contract \(UUID().uuidString.prefix(6))"
let r = try await api.createRecipe(f.createBody())
check(r.images.isEmpty, "new recipe has no photos")
let img = try await api.uploadImage(recipeID: r.id, jpeg: jpeg)
check(img.width == 2048 && img.position == 0, "upload: \(img.width)x\(img.height)")
check(img.urlsExpireAt > Date(), "urls expire in the future")
let full = AppConfig.resolve(img.url)
check(full?.absoluteString.hasPrefix("http://127.0.0.1:8000/v1/image-files/users/") == true, "resolves against server: \(full?.absoluteString.prefix(60) ?? "nil")")
let (data, resp) = try await URLSession.shared.data(from: full!)  // no Authorization header
check((resp as? HTTPURLResponse)?.statusCode == 200 && data.count > 1000, "signed URL loads without a token (\(data.count) bytes)")
let detail = try await api.recipe(id: r.id)
check(detail.images.map(\.id) == [img.id], "detail decodes images")
let page = try await api.listRecipes(search: "Photo contract")
check(page.items.first { $0.id == r.id }?.thumbnailUrl != nil, "list summary has thumbnail")
do {
    _ = try await api.uploadImage(recipeID: r.id, jpeg: Data("not an image".utf8))
    check(false, "garbage upload should fail")
} catch let e as APIError {
    if case .server(422, let b) = e { check(b.code == "invalid_image", "garbage → 422 invalid_image: \(b.message)") } else { check(false, "\(e)") }
}
try await api.deleteImage(recipeID: r.id, imageID: img.id)
// Ephemeral session: the shared one may serve the copy this device already downloaded
// (Cache-Control: private, max-age ≤ TTL), which is fine; the server must refuse a fresh read.
let (_, after) = try await URLSession(configuration: .ephemeral).data(from: full!)
check((after as? HTTPURLResponse)?.statusCode == 404, "deleted photo: server returns 404 within TTL")
try await api.deleteRecipe(id: r.id)
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
