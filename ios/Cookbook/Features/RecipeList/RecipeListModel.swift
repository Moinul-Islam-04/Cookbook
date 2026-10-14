import Foundation
import Observation

/// Cursor-paginated list of the user's recipes, newest first, optionally filtered by a
/// search over titles and ingredient names.
@Observable
final class RecipeListModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(APIError)
    }

    private(set) var recipes: [RecipeSummary] = []
    private(set) var phase: Phase = .loading
    private(set) var isLoadingMore = false
    /// A failed "load more" leaves the rows already shown in place.
    private(set) var loadMoreError: APIError?
    private var nextCursor: String?
    /// The search the current rows and cursor belong to.
    private(set) var activeSearch = ""

    private let api: APIClient

    init(api: APIClient = APIClient()) {
        self.api = api
    }

    var hasMore: Bool { nextCursor != nil }

    /// Loads the first page for `search` (or the current search). Existing rows stay
    /// visible during a pull-to-refresh of the same search.
    func refresh(search: String? = nil) async {
        let term = (search ?? activeSearch).trimmed
        if term != activeSearch {
            // A new search starts from page one; the old cursor can't continue it, and the
            // old rows mustn't be shown under the new search if this request fails.
            activeSearch = term
            recipes = []
            nextCursor = nil
            loadMoreError = nil
        }
        if recipes.isEmpty { phase = .loading }
        do {
            let page = try await api.listRecipes(search: term)
            // A newer search started while this one was in flight; its result wins.
            guard term == activeSearch else { return }
            recipes = page.items
            nextCursor = page.nextCursor
            loadMoreError = nil
            phase = .loaded
        } catch is CancellationError {
            // The view went away mid-request; keep whatever is on screen.
        } catch {
            if recipes.isEmpty {
                phase = .failed(error.asAPIError)
            } else {
                loadMoreError = error.asAPIError
            }
        }
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        let term = activeSearch
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.listRecipes(search: term, cursor: cursor)
            guard term == activeSearch else { return }
            // Keyset pagination doesn't repeat rows, but a refresh racing a page load could.
            let known = Set(recipes.map(\.id))
            recipes += page.items.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
            loadMoreError = nil
        } catch is CancellationError {
        } catch {
            loadMoreError = error.asAPIError
        }
    }

    /// Deletes on the server first; the row only disappears once the server confirms.
    func delete(id: UUID) async throws {
        try await api.deleteRecipe(id: id)
        recipes.removeAll { $0.id == id }
    }

    /// A recipe was created or edited elsewhere; reload so order and counts match the server.
    func recipeSaved() async {
        await refresh()
    }

    func recipeDeleted(id: UUID) {
        recipes.removeAll { $0.id == id }
    }
}
