import Foundation

// Wire types for /v1/import-drafts, mirroring backend/app/schemas.py.

nonisolated struct ImportDraft: Decodable, Identifiable, Equatable {
    let id: UUID
    /// "ready" until saved as a recipe, then "saved".
    let status: String
    /// The caption exactly as pasted; shown above the review form.
    let sourceText: String
    let sourceUrl: String?
    let title: String?
    let ingredients: [IngredientDraft]
    let steps: [StepDraft]
    let warnings: [DraftWarning]
    let extractionVersion: String
    let version: Int
    let savedRecipeId: UUID?
    let expiresAt: Date
}

nonisolated struct IngredientDraft: Decodable, Equatable {
    let name: String?
    let quantity: Decimal?
    let unit: String?
    let rawText: String
    /// The server couldn't match this row to the caption; highlight it for the user.
    let needsReview: Bool
    let reviewReasons: [String]
}

nonisolated struct StepDraft: Decodable, Equatable {
    let instruction: String
    let needsReview: Bool
    let reviewReasons: [String]
}

nonisolated struct DraftWarning: Decodable, Equatable, Identifiable {
    let code: String
    let message: String
    let field: String?
    /// For duplicate_post: the recipe that already has this post.
    let recipeId: UUID?

    var id: String { code + (field ?? "") + message }
}

nonisolated struct ImportDraftCreate: Encodable {
    var sourceText: String
    var sourceUrl: String?
}

nonisolated struct IngredientDraftInput: Encodable, Equatable {
    var name: String?
    var quantity: Decimal?
    var unit: String?
    var rawText: String
    var needsReview: Bool
}

nonisolated struct StepDraftInput: Encodable, Equatable {
    var instruction: String
    var needsReview: Bool
}

nonisolated struct ImportDraftPatch: Encodable {
    var version: Int
    var title: String?
    var ingredients: [IngredientDraftInput]?
    var steps: [StepDraftInput]?
}
