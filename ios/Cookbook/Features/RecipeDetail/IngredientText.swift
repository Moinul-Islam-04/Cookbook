import Foundation

/// Display formatting for an ingredient line. Only adds emphasis: the characters shown are
/// always exactly the recipe's raw_text.
nonisolated enum IngredientText {
    /// raw_text with its amount ("1.5KG", "2 Tsp", "1/3 cup") in bold, so a list can be
    /// scanned by quantity. The amount is the text before the ingredient's name; with no
    /// recorded quantity or unit ("salt to taste") nothing is emphasized.
    static func emphasized(rawText: String, name: String, quantity: Decimal?, unit: String?) -> AttributedString {
        var text = AttributedString(rawText)
        guard quantity != nil || unit != nil, let amount = amountRange(in: rawText, name: name) else { return text }
        let lower = AttributedString.Index(amount.lowerBound, within: text)!
        let upper = AttributedString.Index(amount.upperBound, within: text)!
        text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        return text
    }

    /// The note to show under the line, or nil when raw_text already says it. Imported
    /// lines usually include it ("2 onions, finely chopped"); a note typed in the editor
    /// isn't part of the composed raw_text.
    static func separateNote(rawText: String, note: String?) -> String? {
        guard let note = note?.trimmingCharacters(in: .whitespaces), !note.isEmpty,
              rawText.range(of: note, options: [.caseInsensitive, .diacriticInsensitive]) == nil else { return nil }
        return note
    }

    /// The leading amount, without trailing spaces, or nil if there isn't a clear one.
    static func amountRange(in rawText: String, name: String) -> Range<String.Index>? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let prefixEnd: String.Index
        if !trimmedName.isEmpty,
           let nameRange = rawText.range(of: trimmedName, options: [.caseInsensitive, .diacriticInsensitive]),
           nameRange.lowerBound > rawText.startIndex {
            prefixEnd = nameRange.lowerBound
        } else {
            // Name not found verbatim: fall back to a leading number ("2", "1 1/2", "½").
            guard let match = rawText.range(of: #"^[0-9½¼¾⅓⅔⅛.,/ -]*[0-9½¼¾⅓⅔⅛]"#, options: .regularExpression) else {
                return nil
            }
            prefixEnd = match.upperBound
        }
        var end = prefixEnd
        while end > rawText.startIndex, rawText[rawText.index(before: end)].isWhitespace {
            end = rawText.index(before: end)
        }
        // Must start with a digit or fraction, so "Juice of 1 lemon" isn't half-bolded.
        guard end > rawText.startIndex, let first = rawText.first,
              first.isNumber || "½¼¾⅓⅔⅛".contains(first) else { return nil }
        return rawText.startIndex..<end
    }
}
