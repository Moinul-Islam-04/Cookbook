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
    let sourceUrl: String?
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
    /// Extra context for specific codes: `current_version` on stale_version,
    /// `existing_recipe_id`/`existing_title` on duplicate_recipe.
    let details: Details?

    struct Details: Decodable, Equatable {
        let currentVersion: Int?
        let existingRecipeId: UUID?
        let existingTitle: String?
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

nonisolated struct RecipeCreate: Encodable, Equatable {
    var title: String
    var notes: String?
    /// An Instagram post or reel link; the server normalizes it and rejects other hosts.
    var sourceUrl: String?
    /// True after the user chose "Save Anyway" on a duplicate-post warning.
    var allowDuplicate = false
    var ingredients: [IngredientInput]
    var steps: [StepInput]
}

/// PATCH body. Only fields that changed are sent: an omitted key means "leave unchanged".
nonisolated struct RecipePatch: Encodable {
    var version: Int
    var title: String?
    /// Outer nil: don't touch notes. `.some(nil)`: clear them (sends JSON null).
    var notes: String??
    /// Same convention as notes.
    var sourceUrl: String??
    var allowDuplicate = false
    var ingredients: [IngredientInput]?
    var steps: [StepInput]?

    var isEmpty: Bool {
        title == nil && notes == nil && sourceUrl == nil && ingredients == nil && steps == nil
    }

    private enum CodingKeys: String, CodingKey {
        case version, title, notes, sourceUrl, allowDuplicate, ingredients, steps
    }

    // Hand-written because the synthesized encoder drops nil values, which would make
    // "clear the notes" indistinguishable from "leave the notes alone".
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(title, forKey: .title)
        if let notes { try c.encode(notes, forKey: .notes) }
        if let sourceUrl { try c.encode(sourceUrl, forKey: .sourceUrl) }
        if allowDuplicate { try c.encode(true, forKey: .allowDuplicate) }
        try c.encodeIfPresent(ingredients, forKey: .ingredients)
        try c.encodeIfPresent(steps, forKey: .steps)
    }
}
