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
        /// The server's raw_text and the fields it was loaded with. If the user leaves the
        /// row untouched, the original wording ("salt to taste") is sent back unchanged.
        var original: Original?

        struct Original: Equatable {
            let quantity: String
            let unit: String
            let name: String
            let rawText: String
        }

        var isBlank: Bool { [quantity, unit, name].allSatisfy { $0.trimmed.isEmpty } }
    }

    struct StepRow: Identifiable, Equatable {
        let id = UUID()
        var instruction = ""
    }

    var title = ""
    var notes = ""
    var ingredients: [IngredientRow] = [IngredientRow()]
    var steps: [StepRow] = [StepRow()]

    init() {}

    init(recipe: Recipe) {
        title = recipe.title
        notes = recipe.notes ?? ""
        ingredients = recipe.ingredients.map { ing in
            let quantity = ing.quantity.map(QuantityText.format) ?? ""
            let unit = ing.unit ?? ""
            return IngredientRow(
                quantity: quantity, unit: unit, name: ing.name,
                original: .init(quantity: quantity, unit: unit, name: ing.name, rawText: ing.rawText))
        }
        steps = recipe.steps.map { StepRow(instruction: $0.instruction) }
    }

    // MARK: Validation

    /// Problems the server would also reject, caught before sending. Keyed the same way as
    /// server field errors ("title", "ingredients.2.quantity") so one display path serves both.
    var validationErrors: [String: String] {
        var errors: [String: String] = [:]
        if title.trimmed.isEmpty { errors["title"] = "Give the recipe a title." }
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

    func createBody() -> RecipeCreate {
        RecipeCreate(
            title: title.trimmed,
            notes: notes.trimmed.nilIfEmpty,
            ingredients: ingredientInputs,
            steps: stepInputs)
    }

    /// Sends only what changed relative to `baseline` (the form as loaded from the server).
    func patchBody(version: Int, against baseline: RecipeForm) -> RecipePatch {
        var patch = RecipePatch(version: version)
        if title.trimmed != baseline.title.trimmed { patch.title = title.trimmed }
        if notes.trimmed != baseline.notes.trimmed { patch.notes = .some(notes.trimmed.nilIfEmpty) }
        if ingredientInputs != baseline.ingredientInputs { patch.ingredients = ingredientInputs }
        if stepInputs != baseline.stepInputs { patch.steps = stepInputs }
        return patch
    }

    /// Blank rows are the form's "add another" affordance, not data; they are never sent.
    /// Filtering here also keeps validation indexes aligned with what the server receives.
    private var nonBlankIngredients: [IngredientRow] { ingredients.filter { !$0.isBlank } }

    private var ingredientInputs: [IngredientInput] {
        nonBlankIngredients.map { row in
            let quantity = row.quantity.trimmed
            let unit = row.unit.trimmed
            let name = row.name.trimmed
            let unchanged = row.original.map {
                $0.quantity == quantity && $0.unit == unit && $0.name == name
            } ?? false
            return IngredientInput(
                name: name,
                quantity: QuantityText.parse(quantity),
                unit: unit.nilIfEmpty,
                // Edited rows drop raw_text so the server recomposes it from the new values;
                // otherwise "2 tomatoes" would survive a change to 3.
                rawText: unchanged ? row.original?.rawText : nil)
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
