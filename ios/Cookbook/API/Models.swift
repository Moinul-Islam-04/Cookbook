import Foundation

// Wire types mirroring backend/app/schemas.py. Keep field names and optionality in sync
// with the server; CodingKeys are generated from snake_case by APIClient's coders.

// MARK: - Responses

nonisolated struct Recipe: Decodable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let notes: String?
    let sourceKind: String
    let sourceUrl: String?
    let createdAt: Date
    let updatedAt: Date
    /// Optimistic-concurrency token. PATCH must echo it; a mismatch returns 409 stale_version.
    let version: Int
    let ingredients: [Ingredient]
    let steps: [Step]
    /// Server-computed: "ingredients" and/or "steps" when that list is empty.
    let missing: [String]
}

nonisolated struct Ingredient: Decodable, Identifiable, Equatable {
    let id: UUID
    let position: Int
    let name: String
    /// NUMERIC(10, 3) on the server. Decimal keeps 0.333 exact; null means "not measured".
    let quantity: Decimal?
    let unit: String?
    /// What was actually written, e.g. "salt to taste". Always present on responses.
    let rawText: String
}

nonisolated struct Step: Decodable, Identifiable, Equatable {
    let id: UUID
    let position: Int
    let instruction: String
}

nonisolated struct RecipeSummary: Decodable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let ingredientCount: Int
    let stepCount: Int
    let missing: [String]
    let createdAt: Date
    let updatedAt: Date
}

nonisolated struct RecipePage: Decodable {
    let items: [RecipeSummary]
    let nextCursor: String?
}

/// The single error envelope every failing endpoint returns (backend/app/errors.py).
nonisolated struct ErrorBody: Decodable, Equatable {
    struct FieldError: Decodable, Equatable {
        let field: String
        let message: String
    }

    let code: String
    let message: String
    let fieldErrors: [FieldError]
    let retryable: Bool
    let requestId: String?
    /// Only `current_version` (on stale_version) is read today, so decode just that.
    let details: Details?

    struct Details: Decodable, Equatable {
        let currentVersion: Int?
    }
}

// MARK: - Requests

nonisolated struct IngredientInput: Encodable, Equatable {
    var name: String
    var quantity: Decimal?
    var unit: String?
    /// Omit to let the server compose it from quantity, unit and name.
    var rawText: String?
}

nonisolated struct StepInput: Encodable, Equatable {
    var instruction: String
}

nonisolated struct RecipeCreate: Encodable {
    var title: String
    var notes: String?
    var ingredients: [IngredientInput]
    var steps: [StepInput]
}

/// PATCH body. Only fields that changed are sent: an omitted key means "leave unchanged".
nonisolated struct RecipePatch: Encodable {
    var version: Int
    var title: String?
    /// Outer nil: don't touch notes. `.some(nil)`: clear them (sends JSON null).
    var notes: String??
    var ingredients: [IngredientInput]?
    var steps: [StepInput]?

    var isEmpty: Bool { title == nil && notes == nil && ingredients == nil && steps == nil }

    private enum CodingKeys: String, CodingKey {
        case version, title, notes, ingredients, steps
    }

    // Hand-written because the synthesized encoder drops nil values, which would make
    // "clear the notes" indistinguishable from "leave the notes alone".
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(title, forKey: .title)
        if let notes { try c.encode(notes, forKey: .notes) }
        try c.encodeIfPresent(ingredients, forKey: .ingredients)
        try c.encodeIfPresent(steps, forKey: .steps)
    }
}
