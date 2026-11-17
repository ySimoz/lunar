import Foundation
import Observation

/// A named chapter section of cards for collapsible `DisclosureGroup` rendering.
public struct ChapterGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public var cards: [Flashcard]

    public init(title: String, cards: [Flashcard]) {
        self.id = title
        self.title = title
        self.cards = cards
    }
}

/// Manages card filtering, chapter grouping, reordering, multi-select, and card CRUD for one deck.
@Observable
@MainActor
public final class DeckDetailViewModel {
    public nonisolated static let uncategorizedChapterTitle = "General"

    public var deck: Deck
    public var cards: [Flashcard] = []
    public var filterType: CardType? = nil
    public var filterDifficulty: Difficulty? = nil
    public var dueOnly: Bool = false
    public var searchQuery: String = ""

    public var selectedCardID: String?
    public var isMultiSelectMode: Bool = false
    public var selectedCardIDs: Set<String> = []
    public var expandedChapters: Set<String> = []

    public var isLoading: Bool = false
    public var errorMessage: String?

    private let client: (any CoreClientProtocol)?

    public init(deck: Deck, initialCards: [Flashcard] = [], client: (any CoreClientProtocol)? = nil) {
        self.deck = deck
        self.cards = initialCards.sorted { $0.order < $1.order }
        self.client = client
        self.expandedChapters = Set(
            Self.chapterGroups(
                for: self.cards,
                deckChapters: deck.chapters,
                includeEmptyDeclaredChapters: true
            ).map(\.title)
        )
    }

    // MARK: - Computed Properties

    public var filteredCards: [Flashcard] {
        Self.filterCards(
            cards,
            cardType: filterType,
            difficulty: filterDifficulty,
            dueOnly: dueOnly,
            searchQuery: searchQuery
        )
    }

    public var chapterGroups: [ChapterGroup] {
        Self.chapterGroups(
            for: filteredCards,
            deckChapters: deck.chapters,
            includeEmptyDeclaredChapters: !hasActiveFilters
        )
    }

    public var selectedCard: Flashcard? {
        guard let selectedCardID else { return nil }
        return cards.first { $0.id == selectedCardID }
    }

    public var dueCardsCount: Int {
        cards.filter { $0.isDue() }.count
    }

    public var masteryPercent: Int {
        DeckMetrics.masteryPercent(for: cards)
    }

    public var hasActiveFilters: Bool {
        filterType != nil || filterDifficulty != nil || dueOnly || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Reorder is safe when no filter narrows a chapter's cards.
    public var canReorderCards: Bool {
        !hasActiveFilters
    }

    // MARK: - Pure Filtering & Grouping

    public nonisolated static func filterCards(
        _ cards: [Flashcard],
        cardType: CardType? = nil,
        difficulty: Difficulty? = nil,
        dueOnly: Bool = false,
        searchQuery: String = "",
        now: Date = Date()
    ) -> [Flashcard] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return cards.filter { card in
            if let cardType, card.cardType != cardType {
                return false
            }
            if let difficulty, card.difficulty != difficulty {
                return false
            }
            if dueOnly, !card.isDue(relativeTo: now) {
                return false
            }
            if !trimmed.isEmpty {
                let matchesText = card.front.lowercased().contains(trimmed)
                    || card.back.lowercased().contains(trimmed)
                    || card.topic.lowercased().contains(trimmed)
                    || card.explanation.lowercased().contains(trimmed)
                    || card.tags.contains { $0.lowercased().contains(trimmed) }
                if !matchesText {
                    return false
                }
            }
            return true
        }
    }

    public nonisolated static func chapterGroups(
        for cards: [Flashcard],
        deckChapters: [String],
        includeEmptyDeclaredChapters: Bool = false
    ) -> [ChapterGroup] {
        let grouped = Dictionary(grouping: cards) { card -> String in
            let topic = card.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            return topic.isEmpty ? uncategorizedChapterTitle : topic
        }

        var orderedTitles: [String] = []
        var seen = Set<String>()

        for chapter in deckChapters {
            let trimmed = chapter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            guard includeEmptyDeclaredChapters || grouped[trimmed] != nil else { continue }
            orderedTitles.append(trimmed)
            seen.insert(trimmed)
        }

        let extraTitles = grouped.keys
            .filter { $0 != uncategorizedChapterTitle && !seen.contains($0) }
            .sorted()
        orderedTitles.append(contentsOf: extraTitles)

        if grouped[uncategorizedChapterTitle] != nil && !seen.contains(uncategorizedChapterTitle) {
            orderedTitles.append(uncategorizedChapterTitle)
        }

        return orderedTitles.compactMap { title in
            let chapterCards = grouped[title] ?? []
            if !includeEmptyDeclaredChapters && chapterCards.isEmpty {
                return nil
            }
            return ChapterGroup(title: title, cards: chapterCards)
        }
    }

    // MARK: - Selection & Expansion Helpers

    /// Synchronously updates the view model when switching decks in-place without tearing down the SwiftUI view.
    public func sync(deck: Deck, cards cachedCards: [Flashcard]) {
        let isDifferentDeck = self.deck.id != deck.id
        self.deck = deck
        self.cards = cachedCards.sorted { $0.order < $1.order }

        if isDifferentDeck {
            selectedCardID = nil
            isMultiSelectMode = false
            selectedCardIDs.removeAll()
            filterType = nil
            filterDifficulty = nil
            dueOnly = false
            searchQuery = ""
            isLoading = false
            errorMessage = nil
            expandedChapters = Set(
                Self.chapterGroups(
                    for: self.cards,
                    deckChapters: deck.chapters,
                    includeEmptyDeclaredChapters: true
                ).map(\.title)
            )
        }
    }

    public func isChapterExpanded(_ title: String) -> Bool {
        expandedChapters.contains(title)
    }

    public func setChapter(_ title: String, expanded: Bool) {
        if expanded {
            expandedChapters.insert(title)
        } else {
            expandedChapters.remove(title)
        }
    }

    public func clearFilters() {
        filterType = nil
        filterDifficulty = nil
        dueOnly = false
        searchQuery = ""
    }

    public func toggleMultiSelect() {
        isMultiSelectMode.toggle()
        if !isMultiSelectMode {
            selectedCardIDs.removeAll()
        }
    }

    public func toggleCardSelection(_ id: String) {
        if selectedCardIDs.contains(id) {
            selectedCardIDs.remove(id)
        } else {
            selectedCardIDs.insert(id)
        }
    }

    // MARK: - API Operations

    public func loadCards() async {
        guard let client else { return }
        let targetDeckId = deck.id
        if cards.isEmpty {
            isLoading = true
        }
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await client.listDeckCards(deckId: targetDeckId)
            guard self.deck.id == targetDeckId else { return }
            self.cards = loaded
            let allChapterTitles = Set(
                Self.chapterGroups(
                    for: loaded,
                    deckChapters: deck.chapters,
                    includeEmptyDeclaredChapters: true
                ).map(\.title)
            )
            if expandedChapters.isEmpty {
                expandedChapters = allChapterTitles
            } else {
                expandedChapters.formUnion(allChapterTitles)
            }
            if let selectedCardID, !loaded.contains(where: { $0.id == selectedCardID }) {
                self.selectedCardID = nil
            }
        } catch {
            if self.deck.id == targetDeckId {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    public func saveCard(_ draft: Flashcard, isNew: Bool) async -> Flashcard? {
        guard let client else { return nil }
        do {
            let saved: Flashcard
            if isNew {
                var newCard = draft
                newCard.deckId = deck.id
                newCard.order = cards.count
                saved = try await client.createCard(newCard)
                cards.append(saved)
            } else {
                saved = try await client.updateCard(id: draft.id, draft)
                if let idx = cards.firstIndex(where: { $0.id == saved.id }) {
                    cards[idx] = saved
                }
            }
            let chapterTitle = saved.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.uncategorizedChapterTitle
                : saved.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            expandedChapters.insert(chapterTitle)
            selectedCardID = saved.id
            errorMessage = nil
            return saved
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func deleteCard(id: String) async {
        guard let client else { return }
        do {
            try await client.deleteCard(id: id)
            cards.removeAll { $0.id == id }
            selectedCardIDs.remove(id)
            if selectedCardID == id {
                selectedCardID = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteSelectedCards() async {
        let idsToDelete = Array(selectedCardIDs)
        guard !idsToDelete.isEmpty else { return }
        for id in idsToDelete {
            await deleteCard(id: id)
        }
        isMultiSelectMode = false
        selectedCardIDs.removeAll()
    }

    public func moveSelectedCards(toChapter chapter: String) async {
        guard let client else { return }
        let idsToMove = selectedCardIDs
        guard !idsToMove.isEmpty else { return }

        for idx in cards.indices where idsToMove.contains(cards[idx].id) {
            var updated = cards[idx]
            updated.topic = chapter == Self.uncategorizedChapterTitle ? "" : chapter
            do {
                let saved = try await client.updateCard(id: updated.id, updated)
                cards[idx] = saved
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        expandedChapters.insert(chapter)
        isMultiSelectMode = false
        selectedCardIDs.removeAll()
    }

    /// Transfers one or more cards to `targetDeckId`, optional `targetTopic`, and optional `targetIndex` via `POST /api/cards/transfer`.
    @discardableResult
    public func transferCards(
        cardIds: [String],
        targetDeckId: String,
        targetTopic: String?,
        targetIndex: Int? = nil
    ) async -> Int? {
        let uniqueIds = Array(NSOrderedSet(array: cardIds).compactMap { $0 as? String })
            .filter { !$0.isEmpty }
        guard !uniqueIds.isEmpty, !targetDeckId.isEmpty else { return nil }

        let trimmedTopic = (targetTopic ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTopic = trimmedTopic == Self.uncategorizedChapterTitle ? "" : trimmedTopic

        let movedCount: Int
        if let client {
            do {
                movedCount = try await client.transferCards(
                    cardIds: uniqueIds,
                    targetDeckId: targetDeckId,
                    targetTopic: normalizedTopic.isEmpty ? nil : normalizedTopic,
                    targetIndex: targetIndex
                )
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        } else {
            movedCount = uniqueIds.count
        }

        let movedSet = Set(uniqueIds)
        if targetDeckId == deck.id {
            if let client, targetIndex != nil {
                // Reload authoritative deck order when indexed insertion re-sequenced cards on the backend.
                if let refreshed = try? await client.listDeckCards(deckId: deck.id) {
                    cards = refreshed.sorted { $0.order < $1.order }
                }
            } else {
                for idx in cards.indices where movedSet.contains(cards[idx].id) {
                    cards[idx].topic = normalizedTopic
                }
                if let targetIndex {
                    let movedCards = cards.filter { movedSet.contains($0.id) }
                    var remaining = cards.filter { !movedSet.contains($0.id) }
                    let chapterIndices = remaining.indices.filter { remaining[$0].topic == normalizedTopic }
                    let clamped = min(max(targetIndex, 0), chapterIndices.count)
                    let insertOffset: Int = if chapterIndices.isEmpty {
                        remaining.count
                    } else if clamped >= chapterIndices.count {
                        (chapterIndices.last ?? remaining.count - 1) + 1
                    } else {
                        chapterIndices[clamped]
                    }
                    remaining.insert(contentsOf: movedCards, at: insertOffset)
                    for idx in remaining.indices {
                        remaining[idx].order = idx
                    }
                    cards = remaining
                }
            }
            if !normalizedTopic.isEmpty && !deck.chapters.contains(normalizedTopic) {
                deck.chapters.append(normalizedTopic)
            }
            let expandKey = normalizedTopic.isEmpty ? Self.uncategorizedChapterTitle : normalizedTopic
            expandedChapters.insert(expandKey)
        } else {
            cards.removeAll { movedSet.contains($0.id) }
            if let selectedCardID, movedSet.contains(selectedCardID) {
                self.selectedCardID = nil
            }
        }

        selectedCardIDs.subtract(movedSet)
        if selectedCardIDs.isEmpty {
            isMultiSelectMode = false
        }
        errorMessage = nil
        return movedCount
    }

    // MARK: - Inline Chapter CRUD

    @discardableResult
    public func addChapter(_ title: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != Self.uncategorizedChapterTitle,
              !deck.chapters.contains(trimmed)
        else { return false }

        var updatedDeck = deck
        updatedDeck.chapters.append(trimmed)

        if let client {
            do {
                deck = try await client.updateDeck(id: deck.id, updatedDeck)
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        } else {
            deck = updatedDeck
        }

        expandedChapters.insert(trimmed)
        errorMessage = nil
        return true
    }

    @discardableResult
    public func renameChapter(old: String, new: String) async -> Bool {
        let oldTrimmed = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty,
              !newTrimmed.isEmpty,
              oldTrimmed != Self.uncategorizedChapterTitle,
              newTrimmed != Self.uncategorizedChapterTitle,
              oldTrimmed != newTrimmed
        else { return false }

        var updatedChapters = deck.chapters
        if let idx = updatedChapters.firstIndex(of: oldTrimmed) {
            if updatedChapters.contains(newTrimmed) {
                updatedChapters.remove(at: idx)
            } else {
                updatedChapters[idx] = newTrimmed
            }
        } else if !updatedChapters.contains(newTrimmed) {
            updatedChapters.append(newTrimmed)
        }

        var updatedDeck = deck
        updatedDeck.chapters = updatedChapters

        if let client {
            do {
                deck = try await client.updateDeck(id: deck.id, updatedDeck)
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        } else {
            deck = updatedDeck
        }

        for idx in cards.indices where cards[idx].topic.trimmingCharacters(in: .whitespacesAndNewlines) == oldTrimmed {
            var updatedCard = cards[idx]
            updatedCard.topic = newTrimmed
            if let client {
                do {
                    cards[idx] = try await client.updateCard(id: updatedCard.id, updatedCard)
                } catch {
                    errorMessage = error.localizedDescription
                    return false
                }
            } else {
                cards[idx] = updatedCard
            }
        }

        if expandedChapters.remove(oldTrimmed) != nil {
            expandedChapters.insert(newTrimmed)
        } else {
            expandedChapters.insert(newTrimmed)
        }
        errorMessage = nil
        return true
    }

    @discardableResult
    public func deleteChapter(_ chapter: String, deleteCards: Bool) async -> Bool {
        let trimmed = chapter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != Self.uncategorizedChapterTitle else { return false }

        var updatedDeck = deck
        updatedDeck.chapters.removeAll { $0 == trimmed }

        if let client {
            do {
                deck = try await client.updateDeck(id: deck.id, updatedDeck)
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        } else {
            deck = updatedDeck
        }

        let matchingCards = cards.filter {
            $0.topic.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }

        if deleteCards {
            for card in matchingCards {
                if let client {
                    do {
                        try await client.deleteCard(id: card.id)
                    } catch {
                        errorMessage = error.localizedDescription
                        return false
                    }
                }
                cards.removeAll { $0.id == card.id }
                selectedCardIDs.remove(card.id)
                if selectedCardID == card.id {
                    selectedCardID = nil
                }
            }
        } else {
            var movedAny = false
            for idx in cards.indices where cards[idx].topic.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                var updatedCard = cards[idx]
                updatedCard.topic = ""
                if let client {
                    do {
                        cards[idx] = try await client.updateCard(id: updatedCard.id, updatedCard)
                    } catch {
                        errorMessage = error.localizedDescription
                        return false
                    }
                } else {
                    cards[idx] = updatedCard
                }
                movedAny = true
            }
            if movedAny {
                expandedChapters.insert(Self.uncategorizedChapterTitle)
            }
        }

        expandedChapters.remove(trimmed)
        errorMessage = nil
        return true
    }

    /// Reorders cards within a single chapter and persists the full deck card order.
    public func moveCards(inChapter chapterTitle: String, fromOffsets source: IndexSet, toOffset destination: Int) async {
        guard canReorderCards else { return }
        guard let groupIndex = chapterGroups.firstIndex(where: { $0.title == chapterTitle }) else { return }

        var chapterCards = chapterGroups[groupIndex].cards
        chapterCards.move(fromOffsets: source, toOffset: destination)

        let reorderedChapterIDs = chapterCards.map(\.id)
        var chapterIterator = chapterCards.makeIterator()
        let chapterIDSet = Set(reorderedChapterIDs)

        var newAllCards: [Flashcard] = []
        newAllCards.reserveCapacity(cards.count)
        for card in cards {
            if chapterIDSet.contains(card.id), let next = chapterIterator.next() {
                newAllCards.append(next)
            } else {
                newAllCards.append(card)
            }
        }

        for idx in newAllCards.indices {
            newAllCards[idx].order = idx
        }

        let previousCards = cards
        cards = newAllCards

        guard let client else { return }
        do {
            try await client.reorderCards(deckId: deck.id, cardIds: newAllCards.map(\.id))
            errorMessage = nil
        } catch {
            cards = previousCards
            errorMessage = error.localizedDescription
        }
    }
}
