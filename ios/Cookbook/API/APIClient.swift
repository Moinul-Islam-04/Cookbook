import Foundation

nonisolated enum AppConfig {
    private static let serverKey = "serverURL"

    /// The paired server, else the scheme's COOKBOOK_API_URL, else 127.0.0.1 (the Simulator
    /// shares the Mac's network, so that reaches a local uvicorn in dev mode).
    static var apiBaseURL: URL {
        if let saved = UserDefaults.standard.string(forKey: serverKey), let url = URL(string: saved) {
            return url
        }
        if let override = ProcessInfo.processInfo.environment["COOKBOOK_API_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://127.0.0.1:8000")!
    }

    static var isPaired: Bool { KeychainToken.read() != nil }

    static func pair(_ code: PairingCode) {
        UserDefaults.standard.set(code.server.absoluteString, forKey: serverKey)
        KeychainToken.save(code.token)
    }

    static func unpair() {
        UserDefaults.standard.removeObject(forKey: serverKey)
        KeychainToken.delete()
    }
}

/// Every way a request can fail, kept distinct so the UI never reports a decoding bug
/// as "server unreachable".
nonisolated enum APIError: Error, Equatable {
    /// No HTTP response at all: server down, no network, timeout.
    case transport(URLError.Code)
    /// The server answered with its error envelope.
    case server(status: Int, body: ErrorBody)
    /// The server answered with something that isn't valid JSON for the expected type.
    case badResponse(status: Int, detail: String)

    var isUnauthenticated: Bool {
        if case .server(401, _) = self { return true }
        return false
    }

    var isStaleVersion: Bool {
        if case .server(409, let body) = self, body.code == "stale_version" { return true }
        return false
    }

    /// The post is already in the cookbook: the ID and title of the recipe that has it.
    var duplicateOf: (id: UUID, title: String)? {
        if case .server(409, let body) = self, body.code == "duplicate_recipe",
           let id = body.details?.existingRecipeId {
            return (id, body.details?.existingTitle ?? "")
        }
        return nil
    }

    var fieldErrors: [ErrorBody.FieldError] {
        if case .server(_, let body) = self { return body.fieldErrors }
        return []
    }

    var userMessage: String {
        switch self {
        case .transport(.timedOut):
            return "The server took too long to respond."
        case .transport:
            return "Can't reach the Cookbook server at \(AppConfig.apiBaseURL.host() ?? "localhost"). Is your Mac awake and on Tailscale?"
        case .server(_, let body):
            return body.message
        case .badResponse:
            return "The server sent a response the app couldn't read."
        }
    }

    /// Shown in small print so a failure can be matched to a server log line.
    var debugDetail: String? {
        switch self {
        case .server(_, let body): return body.requestId.map { "Request ID \($0)" }
        case .badResponse(let status, let detail): return "HTTP \(status): \(detail)"
        case .transport(let code): return "URLError \(code.rawValue)"
        }
    }
}

nonisolated struct APIClient {
    /// nil: use the paired server (read per request, so pairing takes effect immediately).
    var baseURL: URL?
    /// nil: use the Keychain token.
    var token: String?
    var session = URLSession.shared

    init(baseURL: URL? = nil, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Reachability only; /healthz needs no token.
    func health() async throws {
        let _: [String: String] = try await send("GET", "healthz")
    }

    // MARK: Recipes

    /// `search` matches titles and ingredient names. A cursor only continues the search it
    /// came from; the server rejects it for any other query.
    func listRecipes(search: String = "", cursor: String? = nil, limit: Int = 20) async throws -> RecipePage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if !search.isEmpty { query.append(URLQueryItem(name: "q", value: search)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send("GET", "v1/recipes", query: query)
    }

    func recipe(id: UUID) async throws -> Recipe {
        try await send("GET", "v1/recipes/\(id.uuidString.lowercased())")
    }

    /// Retrying with the same `idempotencyKey` and body returns the original recipe instead
    /// of saving a second copy (e.g. when the first response was lost to a timeout).
    func createRecipe(_ body: RecipeCreate, idempotencyKey: String? = nil) async throws -> Recipe {
        let headers = idempotencyKey.map { ["Idempotency-Key": $0] } ?? [:]
        return try await send("POST", "v1/recipes", headers: headers, body: body)
    }

    func updateRecipe(id: UUID, _ body: RecipePatch) async throws -> Recipe {
        try await send("PATCH", "v1/recipes/\(id.uuidString.lowercased())", body: body)
    }

    func deleteRecipe(id: UUID) async throws {
        let _: Empty = try await send("DELETE", "v1/recipes/\(id.uuidString.lowercased())")
    }

    // MARK: Import drafts

    /// Runs extraction on the server; a local model can take up to the server's 120 s limit.
    func createDraft(_ body: ImportDraftCreate) async throws -> ImportDraft {
        try await send("POST", "v1/import-drafts", body: body, timeout: 150)
    }

    func draft(id: UUID) async throws -> ImportDraft {
        try await send("GET", "v1/import-drafts/\(id.uuidString.lowercased())")
    }

    func updateDraft(id: UUID, _ body: ImportDraftPatch) async throws -> ImportDraft {
        try await send("PATCH", "v1/import-drafts/\(id.uuidString.lowercased())", body: body)
    }

    // MARK: Transport

    private struct Empty: Decodable {}
    private struct NoBody: Encodable {}

    private func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: (some Encodable)? = NoBody?.none,
        timeout: TimeInterval = 15
    ) async throws -> Response {
        var url = (baseURL ?? AppConfig.apiBaseURL).appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer = token ?? KeychainToken.read() {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = try Self.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // A superseded search cancels its task; that's not a failure to show anyone.
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw APIError.transport(error.code)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse(status: 0, detail: "Not an HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? Self.decoder.decode(ErrorBody.self, from: data) {
                throw APIError.server(status: http.statusCode, body: envelope)
            }
            throw APIError.badResponse(status: http.statusCode, detail: "No error envelope")
        }

        if http.statusCode == 204, Response.self == Empty.self {
            return Empty() as! Response
        }
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.badResponse(status: http.statusCode, detail: String(describing: error))
        }
    }

    // MARK: Coding

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom(decodeServerDate)
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    /// The server sends UTC timestamps with microseconds, e.g. "2026-10-14T19:39:17.693103Z".
    /// Older Foundation releases (the iOS 17 era) reject fractional seconds under the
    /// built-in `.iso8601` strategy, so try both shapes explicitly instead of relying on
    /// the OS version.
    static func decodeServerDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        if let date = try? Date.ISO8601FormatStyle().parse(text) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Unrecognized timestamp: \(text)")
    }
}
