import Foundation

/// Editable, string-backed copy of a recipe. The form edits this; `createBody()` and
/// `patchBody(against:)` turn it into wire requests. Kept free of SwiftUI so the
/// conversion rules are plain values that tests can check.
nonisolated struct RecipeForm: Equatable {
    struct IngredientRow: Identifiable, Equatable {
        let id = UUID()
        var quantity = ""
        var unit = ""
        var name = ""
        /// "finely chopped". Optional; kept separate from the name.
        var note = ""
        /// From an import draft: the separately made part this row belongs to. Not editable,
        /// only carried back to the draft.
        var subRecipe: Int?
        /// The server's raw_text and the fields it was loaded with. If the user leaves the
        /// row untouched, the original wording ("salt to taste") is sent back unchanged.
        var original: Original?
        /// From an import draft: why the server couldn't match this row to the caption.
        /// Shown until the user edits the row.
        var reviewReasons: [String] = []

        var needsReview: Bool { !reviewReasons.isEmpty && isUnedited }
        var isUnedited: Bool {
            original.map {
                $0.quantity == quantity.trimmed && $0.unit == unit.trimmed && $0.name == name.trimmed
                    && $0.note == note.trimmed
            } ?? true
        }

        struct Original: Equatable {
            let quantity: String
            let unit: String
            let name: String
            let note: String
            let rawText: String
        }

        var isBlank: Bool { [quantity, unit, name, note].allSatisfy { $0.trimmed.isEmpty } }
    }

    struct StepRow: Identifiable, Equatable {
        let id = UUID()
        var instruction = ""
        var subRecipe: Int?
        var reviewReasons: [String] = []
        var originalInstruction: String?

        var needsReview: Bool { !reviewReasons.isEmpty && instruction.trimmed == originalInstruction }
    }

    var title = ""
    var notes = ""
    /// Whole number of servings, as typed. Empty means not stated.
    var servings = ""
    /// Instagram or TikTok post link, as typed or pasted.
    var sourceUrl = ""
    var ingredients: [IngredientRow] = [IngredientRow()]
    var steps: [StepRow] = [StepRow()]

    init() {}

    init(recipe: Recipe) {
        title = recipe.title
        notes = recipe.notes ?? ""
        servings = recipe.servings.map(String.init) ?? ""
        sourceUrl = recipe.sourceUrl ?? ""
        ingredients = recipe.ingredients.map { ing in
            let quantity = ing.quantity.map(QuantityText.format) ?? ""
            let unit = ing.unit ?? ""
            let note = ing.note ?? ""
            return IngredientRow(
                quantity: quantity, unit: unit, name: ing.name, note: note,
                original: .init(quantity: quantity, unit: unit, name: ing.name, note: note, rawText: ing.rawText))
        }
        steps = recipe.steps.map { StepRow(instruction: $0.instruction) }
    }

    /// The editable form for reviewing an import draft. Rows keep the draft's raw_text as
    /// their original wording and carry its review flags.
    init(draft: ImportDraft) {
        title = draft.title ?? ""
        servings = draft.servings.map(String.init) ?? ""
        sourceUrl = draft.sourceUrl ?? ""
        ingredients = draft.ingredients.map { ing in
            let quantity = ing.quantity.map(QuantityText.format) ?? ""
            let unit = ing.unit ?? ""
            let name = ing.name ?? ""
            let note = ing.note ?? ""
            return IngredientRow(
                quantity: quantity, unit: unit, name: name, note: note, subRecipe: ing.subRecipe,
                original: .init(quantity: quantity, unit: unit, name: name, note: note, rawText: ing.rawText),
                reviewReasons: ing.needsReview ? ing.reviewReasons : [])
        }
        steps = draft.steps.map {
            StepRow(instruction: $0.instruction,
                    subRecipe: $0.subRecipe,
                    reviewReasons: $0.needsReview ? $0.reviewReasons : [],
                    originalInstruction: $0.instruction)
        }
        if ingredients.isEmpty { ingredients = [IngredientRow()] }
        if steps.isEmpty { steps = [StepRow()] }
    }

    // MARK: Validation

    /// Problems the server would also reject, caught before sending. Keyed the same way as
    /// server field errors ("title", "ingredients.2.quantity") so one display path serves both.
    var validationErrors: [String: String] { validationErrors(reviewedImport: false) }

    /// A reviewed import must have at least one ingredient and one step (the server
    /// enforces the same rule); manual recipes may be saved incomplete.
    func validationErrors(reviewedImport: Bool) -> [String: String] {
        var errors: [String: String] = [:]
        if title.trimmed.isEmpty { errors["title"] = "Give the recipe a title." }
        if !servings.trimmed.isEmpty, parsedServings == nil {
            errors["servings"] = "Use a whole number from 1 to 1000."
        }
        if reviewedImport {
            if nonBlankIngredients.isEmpty { errors["ingredients"] = "Add at least one ingredient before saving." }
            if stepInputs.isEmpty { errors["steps"] = "Add at least one step before saving." }
        }
        for (index, row) in nonBlankIngredients.enumerated() {
            if row.name.trimmed.isEmpty {
                errors["ingredients.\(index).name"] = "Add the ingredient's name."
            }
            if !row.quantity.trimmed.isEmpty, QuantityText.parse(row.quantity) == nil {
                errors["ingredients.\(index).quantity"] = "Use a number like 2, 1.5 or 1 1/2."
            }
        }
        return errors
    }

    // MARK: Requests

    func createBody(allowDuplicate: Bool = false, draftID: UUID? = nil) -> RecipeCreate {
        RecipeCreate(
            draftId: draftID,
            title: title.trimmed,
            notes: notes.trimmed.nilIfEmpty,
            servings: parsedServings,
            sourceUrl: sourceUrl.trimmed.nilIfEmpty,
            allowDuplicate: allowDuplicate,
            ingredients: ingredientInputs,
            steps: stepInputs)
    }

    /// Sends only what changed relative to `baseline` (the form as loaded from the server).
    func patchBody(version: Int, against baseline: RecipeForm, allowDuplicate: Bool = false) -> RecipePatch {
        var patch = RecipePatch(version: version)
        patch.allowDuplicate = allowDuplicate
        if title.trimmed != baseline.title.trimmed { patch.title = title.trimmed }
        if notes.trimmed != baseline.notes.trimmed { patch.notes = .some(notes.trimmed.nilIfEmpty) }
        if parsedServings != baseline.parsedServings { patch.servings = .some(parsedServings) }
        if sourceUrl.trimmed != baseline.sourceUrl.trimmed {
            patch.sourceUrl = .some(sourceUrl.trimmed.nilIfEmpty)
        }
        if ingredientInputs != baseline.ingredientInputs { patch.ingredients = ingredientInputs }
        if stepInputs != baseline.stepInputs { patch.steps = stepInputs }
        return patch
    }

    /// Persists the reviewer's corrections to the draft, so they survive a failed save or
    /// an app restart. Sends the whole draft each time; drafts are small.
    func draftPatch(version: Int) -> ImportDraftPatch {
        ImportDraftPatch(
            version: version,
            title: title.trimmed.nilIfEmpty,
            ingredients: zip(nonBlankIngredients, ingredientInputs).map { row, input in
                IngredientDraftInput(
                    name: input.name.nilIfEmpty, quantity: input.quantity, unit: input.unit,
                    // The draft schema needs raw_text; compose it when the server would.
                    rawText: input.rawText ?? [row.quantity.trimmed, row.unit.trimmed, row.name.trimmed]
                        .filter { !$0.isEmpty }.joined(separator: " "),
                    note: input.note, subRecipe: row.subRecipe,
                    needsReview: row.needsReview)
            },
            steps: steps.filter { !$0.instruction.trimmed.isEmpty }.map {
                StepDraftInput(instruction: $0.instruction.trimmed, subRecipe: $0.subRecipe, needsReview: $0.needsReview)
            })
    }

    /// nil when empty or not a whole number the server accepts (1–1000).
    var parsedServings: Int? {
        Int(servings.trimmed).flatMap { (1...1000).contains($0) ? $0 : nil }
    }

    /// Blank rows are the form's "add another" affordance, not data; they are never sent.
    /// Filtering here also keeps validation indexes aligned with what the server receives.
    private var nonBlankIngredients: [IngredientRow] { ingredients.filter { !$0.isBlank } }

    private var ingredientInputs: [IngredientInput] {
        nonBlankIngredients.map { row in
            let quantity = row.quantity.trimmed
            let unit = row.unit.trimmed
            let name = row.name.trimmed
            let note = row.note.trimmed
            // A changed note counts too: the original raw_text may still hold the old one.
            let unchanged = row.original.map {
                $0.quantity == quantity && $0.unit == unit && $0.name == name && $0.note == note
            } ?? false
            let parsed = QuantityText.parse(quantity)
            let rawText: String?
            if unchanged {
                rawText = row.original?.rawText
            } else if let parsed, quantity != QuantityText.format(parsed) {
                // The user wrote "1/3" or "1 1/2": keep their wording rather than letting the
                // server compose "0.333 cup" from the rounded number.
                rawText = [quantity, unit, name].filter { !$0.isEmpty }.joined(separator: " ")
            } else {
                // Edited or new rows with a plain number (or none) let the server compose
                // raw_text from the new values, so "2 tomatoes" doesn't survive a change to 3.
                rawText = nil
            }
            return IngredientInput(
                name: name, quantity: parsed, unit: unit.nilIfEmpty, rawText: rawText, note: note.nilIfEmpty)
        }
    }

    private var stepInputs: [StepInput] {
        steps.map { $0.instruction.trimmed }.filter { !$0.isEmpty }.map(StepInput.init)
    }
}

/// Converts between what people type ("1 1/2", "0.5") and the server's NUMERIC(10, 3).
nonisolated enum QuantityText {
    static func parse(_ text: String) -> Decimal? {
        let parts = text.trimmed.split(separator: " ").map(String.init)
        guard !parts.isEmpty, parts.count <= 2 else { return nil }
        var total = Decimal(0)
        for part in parts {
            guard let value = parseSingle(part) else { return nil }
            total += value
        }
        guard total > 0 else { return nil }
        // The server allows 3 decimal places; round 1/3 to 0.333 rather than get a 422.
        var rounded = Decimal()
        NSDecimalRound(&rounded, &total, 3, .plain)
        return rounded
    }

    static func format(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func parseSingle(_ text: String) -> Decimal? {
        let fraction = text.split(separator: "/", omittingEmptySubsequences: false)
        if fraction.count == 2 {
            guard let n = parseNumber(String(fraction[0])),
                  let d = parseNumber(String(fraction[1])), d != 0 else { return nil }
            return n / d
        }
        return parseNumber(text)
    }

    private static func parseNumber(_ text: String) -> Decimal? {
        // Decimal(string:) accepts a numeric prefix ("2abc" → 2); require the whole token.
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else {
            return nil
        }
        return Decimal(string: text, locale: posix)
    }

    private static let posix = Locale(identifier: "en_US_POSIX")
}

nonisolated extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
