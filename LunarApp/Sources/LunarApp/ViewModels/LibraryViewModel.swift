import Foundation
import CoreGraphics
import Observation

/// Coordinates bounded drag-and-drop movement of a selected flashcard within chapters,
/// across chapters, and onto decks in the sidebar.
@Observable
@MainActor
public final class CardDragCoordinator {
    public var draggingCard: Flashcard?
    public var dragLocation: CGPoint = .zero
    public var workspaceBounds: CGRect = .zero

    public var sidebarDeckFrames: [String: CGRect] = [:]
    public var chapterFrames: [String: CGRect] = [:]
    public var cardFrames: [String: (chapter: String, index: Int, rect: CGRect)] = [:]

    public var hoveredDeckId: String?
    public var hoveredChapter: String?
    public var hoveredInsertIndex: Int?

    public init() {}

    public func updateDrag(card: Flashcard, rawLocation: CGPoint) {
        draggingCard = card
        dragLocation = clampedLocation(rawLocation)

        if let targetDeck = sidebarDeckFrames.first(where: { deckId, rect in
            deckId != card.deckId && rect.contains(dragLocation)
        })?.key {
            hoveredDeckId = targetDeck
            hoveredChapter = nil
            hoveredInsertIndex = nil
            return
        }
        hoveredDeckId = nil

        if let cardHit = cardFrames.values.first(where: { $0.rect.contains(dragLocation) }) {
            let insertBefore = dragLocation.y < cardHit.rect.midY
            hoveredChapter = cardHit.chapter
            hoveredInsertIndex = insertBefore ? cardHit.index : cardHit.index + 1
            return
        }

        if let chapterHit = chapterFrames.first(where: { _, rect in
            rect.contains(dragLocation)
        })?.key {
            hoveredChapter = chapterHit
            hoveredInsertIndex = nil
            return
        }

        hoveredChapter = nil
        hoveredInsertIndex = nil
    }

    public func resetDeckDetailFrames() {
        chapterFrames.removeAll()
        cardFrames.removeAll()
    }

    public func endDrag() {
        draggingCard = nil
        dragLocation = .zero
        hoveredDeckId = nil
        hoveredChapter = nil
        hoveredInsertIndex = nil
    }

    private func clampedLocation(_ point: CGPoint) -> CGPoint {
        guard workspaceBounds.width > 40, workspaceBounds.height > 40 else { return point }
        let safe = workspaceBounds.insetBy(dx: 16, dy: 16)
        return CGPoint(
            x: min(max(point.x, safe.minX), safe.maxX),
            y: min(max(point.y, safe.minY), safe.maxY)
        )
    }
}

/// Coordinates bounded drag-and-drop reordering of deck cards inside the `Library` grid
/// when `Custom Order` is active and no category or search filters are applied.
@Observable
@MainActor
public final class DeckDragCoordinator {
    public var draggingDeck: Deck?
    public var dragLocation: CGPoint = .zero
    public var libraryBounds: CGRect = .zero
    public var deckFrames: [String: CGRect] = [:]
    public var orderedDeckIds: [String] = []
    private var lastSwappedTargetId: String?

    public init() {}

    public func updateDrag(deck: Deck, currentOrder: [String], rawLocation: CGPoint) {
        if draggingDeck == nil {
            draggingDeck = deck
            orderedDeckIds = currentOrder
            lastSwappedTargetId = nil
        }

        dragLocation = clampedLocation(rawLocation)

        if let lastId = lastSwappedTargetId,
           let lastRect = deckFrames[lastId],
           !lastRect.contains(dragLocation) {
            lastSwappedTargetId = nil
        }

        if let targetId = deckFrames.first(where: { id, rect in
            id != deck.id && rect.insetBy(dx: 8, dy: 8).contains(dragLocation)
        })?.key,
           targetId != lastSwappedTargetId,
           let fromIndex = orderedDeckIds.firstIndex(of: deck.id),
           let toIndex = orderedDeckIds.firstIndex(of: targetId) {
            var next = orderedDeckIds
            next.remove(at: fromIndex)
            next.insert(deck.id, at: toIndex)
            orderedDeckIds = next
            lastSwappedTargetId = targetId
        }
    }

    @discardableResult
    public func endDrag() -> [String]? {
        let finalOrder = draggingDeck != nil ? orderedDeckIds : nil
        draggingDeck = nil
        dragLocation = .zero
        lastSwappedTargetId = nil
        orderedDeckIds = []
        return finalOrder
    }

    public func resetFrames() {
        deckFrames.removeAll()
    }

    private func clampedLocation(_ point: CGPoint) -> CGPoint {
        guard libraryBounds.width > 40, libraryBounds.height > 40 else { return point }
        let safe = libraryBounds.insetBy(dx: 24, dy: 24)
        return CGPoint(
            x: min(max(point.x, safe.minX), safe.maxX),
            y: min(max(point.y, safe.minY), safe.maxY)
        )
    }
}

/// Primary sidebar navigation items for the Lunar macOS shell.
public enum SidebarDestination: Hashable, Sendable {
    case today
    case gauntlet
    case library
    case deck(String)
    case analytics
    case tools
}

/// Pure metrics helpers for deck and library summaries.
public enum DeckMetrics {
    public static func masteredCount(in cards: [Flashcard]) -> Int {
        cards.reduce(0) { $0 + ($1.masteryStage == .mastered ? 1 : 0) }
    }

    public static func masteryRatio(for cards: [Flashcard]) -> Double {
        guard !cards.isEmpty else { return 0 }
        return Double(masteredCount(in: cards)) / Double(cards.count)
    }

    public static func masteryPercent(for cards: [Flashcard]) -> Int {
        Int((masteryRatio(for: cards) * 100.0).rounded())
    }
}

/// Coordinates the deck library, sidebar counts, search filtering, preferences, and deck CRUD.
@Observable
@MainActor
public final class LibraryViewModel {
    public var decks: [Deck] = []
    public var cardsByDeck: [String: [Flashcard]] = [:]
    public var preferences: UserPreferences = UserPreferences()
    public var sessions: [StudySessionRecord] = []
    public var activeSession: ActiveSessionState?
    public var requestedImportExportTab: ImportExportTab?
    public var requestedImportExportDeckId: String?
    public var selection: SidebarDestination? = .today
    public var searchQuery: String = ""
    public var isLoading: Bool = false
    public var errorMessage: String?
    public let dragCoordinator = CardDragCoordinator()
    public let deckDragCoordinator = DeckDragCoordinator()

    private var client: (any CoreClientProtocol)?

    public init(client: (any CoreClientProtocol)? = nil) {
        self.client = client
    }

    public func configure(client: any CoreClientProtocol) {
        self.client = client
    }

    // MARK: - Computed Summaries & Filtering

    public var totalCards: Int {
        decks.reduce(0) { $0 + $1.cardCount }
    }

    public var totalDue: Int {
        decks.reduce(0) { $0 + $1.dueCount }
    }

    public var allLoadedCards: [Flashcard] {
        cardsByDeck.values.flatMap { $0 }
    }

    public var overallMasteryPercent: Int {
        DeckMetrics.masteryPercent(for: allLoadedCards)
    }

    public func cards(for deckId: String) -> [Flashcard] {
        cardsByDeck[deckId] ?? []
    }

    public func masteryRatio(for deckId: String) -> Double {
        DeckMetrics.masteryRatio(for: cards(for: deckId))
    }

    public func masteryPercent(for deckId: String) -> Int {
        DeckMetrics.masteryPercent(for: cards(for: deckId))
    }

    /// Returns decks filtered for the active library mode (`allDecks` or `dueToday`) and `searchQuery`.
    public func filteredDecks(onlyDue: Bool) -> [Deck] {
        let base = onlyDue ? decks.filter { $0.dueCount > 0 } : decks
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }

        let lowered = query.lowercased()
        return base.filter { deck in
            if deck.title.lowercased().contains(lowered)
                || deck.description.lowercased().contains(lowered)
                || deck.category.rawValue.lowercased().contains(lowered)
                || deck.difficulty.displayName.lowercased().contains(lowered)
            {
                return true
            }
            return cards(for: deck.id).contains { card in
                card.front.lowercased().contains(lowered)
                    || card.back.lowercased().contains(lowered)
                    || card.topic.lowercased().contains(lowered)
                    || card.tags.contains { $0.lowercased().contains(lowered) }
            }
        }
    }

    public func deck(for id: String) -> Deck? {
        decks.first { $0.id == id }
    }

    /// Returns ordered chapter names combining `deck.chapters` and distinct card topics.
    public func chapterNames(for deck: Deck) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for ch in deck.chapters {
            let trimmed = ch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        for card in cards(for: deck.id) {
            let trimmed = card.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    // MARK: - Data Loading & Mutations

    public func loadAll() async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let decksTask = client.listDecks()
            async let cardsTask = client.listCards(deckId: nil)
            async let prefsTask = client.getPreferences()
            async let activeTask = client.getActiveSession()
            async let sessionsTask = client.listSessions()

            let (loadedDecks, loadedCards, loadedPrefs) = try await (decksTask, cardsTask, prefsTask)
            self.decks = loadedDecks
            self.cardsByDeck = Dictionary(grouping: loadedCards, by: \.deckId)
            self.preferences = loadedPrefs
            self.activeSession = try? await activeTask
            self.sessions = (try? await sessionsTask) ?? []
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    public func refreshActiveSession() async {
        guard let client else { return }
        self.activeSession = try? await client.getActiveSession()
    }

    public func resolveActiveSessionLaunch() -> (deck: Deck, cards: [Flashcard], state: ActiveSessionState)? {
        guard let state = activeSession else { return nil }
        let ids = !state.deckIds.isEmpty ? state.deckIds : (state.deckId.map { [$0] } ?? [])
        guard let firstId = ids.first else { return nil }

        let pooledCards = ids.flatMap { cards(for: $0) }
        guard !pooledCards.isEmpty else { return nil }

        if ids.count == 1, let singleDeck = deck(for: firstId) {
            return (singleDeck, pooledCards, state)
        }
        let syntheticDeck = Deck(
            id: firstId,
            title: "Gauntlet (\(ids.count) decks)",
            cardCount: pooledCards.count
        )
        return (syntheticDeck, pooledCards, state)
    }

    public func discardActiveSession() async {
        guard let client else {
            activeSession = nil
            return
        }
        try? await client.clearActiveSession()
        activeSession = nil
    }

    public func refreshDecks() async {
        guard let client else { return }
        do {
            let loadedDecks = try await client.listDecks()
            self.decks = loadedDecks
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    public func syncCards(_ cards: [Flashcard], for deckId: String) {
        cardsByDeck[deckId] = cards
    }

    @discardableResult
    public func createDeck(
        title: String,
        description: String,
        category: SubjectCategory,
        difficulty: Difficulty,
        chapters: [String]
    ) async -> Deck? {
        guard let client else { return nil }
        let draft = Deck(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            difficulty: difficulty,
            color: "slate",
            chapters: chapters
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        do {
            let created = try await client.createDeck(draft)
            decks.append(created)
            cardsByDeck[created.id] = []
            errorMessage = nil
            return created
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func updateDeck(_ deck: Deck) async -> Deck? {
        guard let client else { return nil }
        do {
            let updated = try await client.updateDeck(id: deck.id, deck)
            if let idx = decks.firstIndex(where: { $0.id == updated.id }) {
                decks[idx] = updated
            }
            errorMessage = nil
            return updated
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func renameDeck(id: String, title: String) async -> Deck? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var existing = deck(for: id) else { return nil }
        existing.title = trimmed
        return await updateDeck(existing)
    }

    @discardableResult
    public func applyLocalDeckOrder(_ orderedIds: [String]) -> [Deck] {
        let deckMap = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
        var reordered: [Deck] = []
        var seen = Set<String>()
        for id in orderedIds where seen.insert(id).inserted {
            if let deck = deckMap[id] {
                reordered.append(deck)
            }
        }
        for deck in decks where seen.insert(deck.id).inserted {
            reordered.append(deck)
        }
        let previous = decks
        decks = reordered
        return previous
    }

    public func persistDeckOrder(orderedIds: [String], rollbackDecks: [Deck]) async {
        guard let client else { return }
        do {
            try await client.reorderDecks(deckIds: orderedIds)
            errorMessage = nil
        } catch {
            decks = rollbackDecks
            errorMessage = error.localizedDescription
        }
    }

    public func reorderDecks(orderedIds: [String]) async {
        let previous = applyLocalDeckOrder(orderedIds)
        await persistDeckOrder(orderedIds: decks.map(\.id), rollbackDecks: previous)
    }

    public func moveDeck(id: String, offset: Int) async {
        guard let currentIndex = decks.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex = currentIndex + offset
        guard decks.indices.contains(targetIndex) else { return }
        var ids = decks.map(\.id)
        let movedId = ids.remove(at: currentIndex)
        ids.insert(movedId, at: targetIndex)
        await reorderDecks(orderedIds: ids)
    }

    public func deleteDeck(id: String) async {
        guard let client else { return }
        do {
            try await client.deleteDeck(id: id)
            decks.removeAll { $0.id == id }
            cardsByDeck.removeValue(forKey: id)
            if selection == .deck(id) {
                selection = .today
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func buildTodayDueStudyRequest(now: Date = Date()) -> StudyLaunchRequest? {
        var dueCards: [Flashcard] = []
        var dueDecks: [Deck] = []
        for deck in decks {
            let deckDue = cards(for: deck.id).filter { $0.isDue(relativeTo: now) }
            if !deckDue.isEmpty {
                dueDecks.append(deck)
                dueCards.append(contentsOf: deckDue)
            }
        }
        guard !dueCards.isEmpty, let firstDeck = dueDecks.first else { return nil }
        if dueDecks.count == 1 {
            return StudyLaunchRequest(deck: firstDeck, cards: dueCards, mode: .standard)
        }
        let syntheticDeck = Deck(
            id: firstDeck.id,
            title: "Due Today",
            cardCount: dueCards.count,
            dueCount: dueCards.count
        )
        return StudyLaunchRequest(
            deck: syntheticDeck,
            cards: dueCards,
            mode: .standard,
            deckIds: dueDecks.map(\.id),
            deckTitles: dueDecks.map(\.title)
        )
    }

    public func updatePreferences(_ updated: UserPreferences) async {
        guard let client else { return }
        do {
            self.preferences = try await client.updatePreferences(updated)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
