import Foundation
import Testing
@testable import LunarApp

private actor MockCoreClient: CoreClientProtocol {
    var decks: [Deck]
    var cards: [Flashcard]
    var preferences: UserPreferences
    var reorderCalls: [(deckId: String, cardIds: [String])] = []
    var transferCalls: [TransferCardsRequest] = []

    init(decks: [Deck], cards: [Flashcard], preferences: UserPreferences = UserPreferences()) {
        self.decks = decks
        self.cards = cards
        self.preferences = preferences
    }

    func health() async throws -> Bool { true }
    func listDecks() async throws -> [Deck] { decks }

    func createDeck(_ deck: Deck) async throws -> Deck {
        var created = deck
        if created.id.isEmpty { created.id = "deck-\(decks.count + 1)" }
        decks.append(created)
        return created
    }

    func updateDeck(id: String, _ deck: Deck) async throws -> Deck {
        if let idx = decks.firstIndex(where: { $0.id == id }) {
            decks[idx] = deck
        }
        return deck
    }

    func deleteDeck(id: String) async throws {
        decks.removeAll { $0.id == id }
        cards.removeAll { $0.deckId == id }
    }

    func reorderDecks(deckIds: [String]) async throws {
        let byId = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
        var reordered = deckIds.compactMap { byId[$0] }
        let seen = Set(reordered.map(\.id))
        reordered.append(contentsOf: decks.filter { !seen.contains($0.id) })
        decks = reordered
    }

    func listDeckCards(deckId: String) async throws -> [Flashcard] {
        cards.filter { $0.deckId == deckId }.sorted { $0.order < $1.order }
    }

    func listCards(deckId: String?) async throws -> [Flashcard] {
        if let deckId { return try await listDeckCards(deckId: deckId) }
        return cards
    }

    func createCard(_ card: Flashcard) async throws -> Flashcard {
        var created = card
        if created.id.isEmpty { created.id = "card-\(cards.count + 1)" }
        cards.append(created)
        return created
    }

    func updateCard(id: String, _ card: Flashcard) async throws -> Flashcard {
        if let idx = cards.firstIndex(where: { $0.id == id }) {
            cards[idx] = card
        }
        return card
    }

    func deleteCard(id: String) async throws {
        cards.removeAll { $0.id == id }
    }

    func reorderCards(deckId: String, cardIds: [String]) async throws {
        reorderCalls.append((deckId: deckId, cardIds: cardIds))
    }

    func reviewCard(id: String, rating: Int, durationMs: Int64?) async throws -> Flashcard {
        cards.first { $0.id == id }!
    }

    func predictCard(id: String) async throws -> [String: IntervalPrediction] { [:] }
    func listSessions() async throws -> [StudySessionRecord] { [] }
    func createSession(_ session: StudySessionRecord) async throws -> StudySessionRecord { session }
    func getActiveSession() async throws -> ActiveSessionState? { nil }
    func saveActiveSession(_ state: ActiveSessionState) async throws -> ActiveSessionState { state }
    func clearActiveSession() async throws {}
    func getPreferences() async throws -> UserPreferences { preferences }

    func updatePreferences(_ preferences: UserPreferences) async throws -> UserPreferences {
        self.preferences = preferences
        return preferences
    }

    func exportDeck(deckId: String, format: IOFormat) async throws -> ExportResult {
        ExportResult(filename: "export.\(format.fileExtension)", content: "", mimeType: "text/plain")
    }

    func importCards(_ request: ImportRequest) async throws -> ImportResult {
        ImportResult(deck: decks.first ?? Deck(title: "Imported"), importedCount: 0, cards: [])
    }

    func getStats(days: Int) async throws -> StatsSummary {
        StatsSummary()
    }

    @discardableResult
    func transferCards(cardIds: [String], targetDeckId: String, targetTopic: String?, targetIndex: Int?) async throws -> Int {
        transferCalls.append(TransferCardsRequest(cardIds: cardIds, targetDeckId: targetDeckId, targetTopic: targetTopic, targetIndex: targetIndex))
        let topic = (targetTopic ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty, let dIdx = decks.firstIndex(where: { $0.id == targetDeckId }) {
            if !decks[dIdx].chapters.contains(topic) {
                decks[dIdx].chapters.append(topic)
            }
        }
        var moved = 0
        for idx in cards.indices where cardIds.contains(cards[idx].id) {
            cards[idx].deckId = targetDeckId
            cards[idx].topic = topic
            moved += 1
        }
        return moved
    }
}

@Suite("ViewModel Filtering, Grouping & Reordering")
@MainActor
struct ViewModelTests {
    private func sampleData() -> ([Deck], [Flashcard]) {
        let deck1 = Deck(
            id: "deck-1",
            title: "Real Analysis",
            description: "Limits and sequences",
            category: .realAnalysis,
            difficulty: .hard,
            cardCount: 3,
            dueCount: 2,
            chapters: ["Limits", "Sequences"]
        )
        let deck2 = Deck(
            id: "deck-2",
            title: "Topology",
            description: "Compactness",
            category: .topology,
            difficulty: .master,
            cardCount: 1,
            dueCount: 0,
            chapters: ["Compactness"]
        )

        let cards = [
            Flashcard(
                id: "c1",
                deckId: "deck-1",
                topic: "Sequences",
                order: 0,
                cardType: .theorem,
                front: "Bolzano-Weierstrass Theorem",
                back: "Bounded sequence has convergent subsequence",
                difficulty: .hard,
                tags: ["completeness"],
                repetition: 3,
                intervalDays: 30,
                nextReviewDate: "2099-01-01T04:00:00Z",
                totalReviews: 4,
                correctCount: 4
            ),
            Flashcard(
                id: "c2",
                deckId: "deck-1",
                topic: "Limits",
                order: 1,
                cardType: .definition,
                front: "Epsilon-Delta Limit",
                back: "For all epsilon > 0...",
                difficulty: .medium,
                tags: ["limit"],
                repetition: 0,
                intervalDays: 1,
                nextReviewDate: "2020-01-01T04:00:00Z",
                totalReviews: 0
            ),
            Flashcard(
                id: "c3",
                deckId: "deck-1",
                topic: "",
                order: 2,
                cardType: .example,
                front: "Counterexample to uniform continuity",
                back: "f(x) = x^2 on R",
                difficulty: .easy,
                tags: [],
                repetition: 1,
                intervalDays: 1,
                nextReviewDate: "2020-01-01T04:00:00Z",
                totalReviews: 1,
                correctCount: 1
            ),
            Flashcard(
                id: "c4",
                deckId: "deck-2",
                topic: "Compactness",
                order: 0,
                cardType: .theorem,
                front: "Heine-Borel",
                back: "Closed and bounded",
                difficulty: .master,
                repetition: 4,
                intervalDays: 45,
                nextReviewDate: "2099-01-01T04:00:00Z",
                totalReviews: 5,
                correctCount: 5
            )
        ]

        return ([deck1, deck2], cards)
    }

    @Test("LibraryViewModel loads data, computes mastery, and filters due/search")
    func libraryViewModelFilteringAndMetrics() async {
        let (decks, cards) = sampleData()
        let mock = MockCoreClient(decks: decks, cards: cards)
        let vm = LibraryViewModel(client: mock)

        await vm.loadAll()

        #expect(vm.decks.count == 2)
        #expect(vm.totalCards == 4)
        #expect(vm.totalDue == 2)
        // c1 and c4 are mastered out of 4 total cards => 50%
        #expect(vm.overallMasteryPercent == 50)
        #expect(vm.masteryPercent(for: "deck-1") == 33)
        #expect(vm.masteryPercent(for: "deck-2") == 100)

        #expect(vm.filteredDecks(onlyDue: true).map(\.id) == ["deck-1"])

        vm.searchQuery = "uniform continuity"
        #expect(vm.filteredDecks(onlyDue: false).map(\.id) == ["deck-1"])

        vm.searchQuery = "Topology"
        #expect(vm.filteredDecks(onlyDue: false).map(\.id) == ["deck-2"])

        // SidebarDestination defaults to .today and Today due study builder pools due cards
        #expect(vm.selection == .today)
        let todayReq = vm.buildTodayDueStudyRequest()
        #expect(todayReq?.cards.map(\.id) == ["c2", "c3"])
        #expect(todayReq?.deck.id == "deck-1")

        // Deleting selected deck resets selection to .today
        vm.selection = .deck("deck-2")
        await vm.deleteDeck(id: "deck-2")
        #expect(vm.selection == .today)
    }

    @Test("DeckDetailViewModel filters by CardType, Difficulty, dueOnly, and groups chapters in deck order")
    func deckDetailFilteringAndGrouping() {
        let (decks, cards) = sampleData()
        let deck1 = decks[0]
        let deck1Cards = cards.filter { $0.deckId == deck1.id }
        let vm = DeckDetailViewModel(deck: deck1, initialCards: deck1Cards)

        // Chapter grouping follows deck1.chapters ("Limits", "Sequences") then "General"
        let groups = vm.chapterGroups
        #expect(groups.map(\.title) == ["Limits", "Sequences", "General"])
        #expect(groups[0].cards.map(\.id) == ["c2"])
        #expect(groups[1].cards.map(\.id) == ["c1"])
        #expect(groups[2].cards.map(\.id) == ["c3"])

        vm.filterType = .theorem
        #expect(vm.filteredCards.map(\.id) == ["c1"])
        #expect(!vm.canReorderCards)

        vm.filterType = nil
        vm.filterDifficulty = .easy
        #expect(vm.filteredCards.map(\.id) == ["c3"])

        vm.filterDifficulty = nil
        vm.dueOnly = true
        #expect(vm.filteredCards.map(\.id) == ["c2", "c3"])

        vm.clearFilters()
        #expect(vm.filteredCards.count == 3)
        #expect(vm.canReorderCards)
    }

    @Test("DeckDetailViewModel moveCards reorders within chapter and sends full deck order to CoreClient")
    func deckDetailReorderAndMultiSelect() async {
        let deck = Deck(id: "deck-1", title: "Algebra", chapters: ["Groups", "Rings"])
        let cards = [
            Flashcard(id: "g1", deckId: "deck-1", topic: "Groups", order: 0, cardType: .definition, front: "G1", back: "B1"),
            Flashcard(id: "r1", deckId: "deck-1", topic: "Rings", order: 1, cardType: .definition, front: "R1", back: "B2"),
            Flashcard(id: "g2", deckId: "deck-1", topic: "Groups", order: 2, cardType: .theorem, front: "G2", back: "B3")
        ]

        let mock = MockCoreClient(decks: [deck], cards: cards)
        let vm = DeckDetailViewModel(deck: deck, initialCards: cards, client: mock)

        // Move second item in "Groups" (g2) before first item (g1)
        await vm.moveCards(inChapter: "Groups", fromOffsets: IndexSet(integer: 1), toOffset: 0)

        #expect(vm.cards.map(\.id) == ["g2", "r1", "g1"])
        let recorded = await mock.reorderCalls
        #expect(recorded.count == 1)
        #expect(recorded[0].deckId == "deck-1")
        #expect(recorded[0].cardIds == ["g2", "r1", "g1"])

        // Multi-select move to Rings
        vm.toggleMultiSelect()
        vm.toggleCardSelection("g1")
        await vm.moveSelectedCards(toChapter: "Rings")
        #expect(vm.cards.first(where: { $0.id == "g1" })?.topic == "Rings")
        #expect(!vm.isMultiSelectMode)
        #expect(vm.selectedCardIDs.isEmpty)
    }

    @Test("TransferCardsRequest Codable and DeckDetailViewModel transferCards + inline Chapter CRUD")
    func transferCardsAndChapterCRUD() async throws {
        let req = TransferCardsRequest(cardIds: ["c1", "c2"], targetDeckId: "deck-2", targetTopic: "Metric Spaces")
        let reqData = try JSONEncoder().encode(req)
        let reqObj = try JSONSerialization.jsonObject(with: reqData) as! [String: Any]
        #expect(reqObj["cardIds"] as? [String] == ["c1", "c2"])
        #expect(reqObj["targetDeckId"] as? String == "deck-2")
        #expect(reqObj["targetTopic"] as? String == "Metric Spaces")

        let (decks, cards) = sampleData()
        let deck1 = decks[0]
        let deck1Cards = cards.filter { $0.deckId == deck1.id }
        let mock = MockCoreClient(decks: decks, cards: cards)
        let vm = DeckDetailViewModel(deck: deck1, initialCards: deck1Cards, client: mock)

        // 1. Add empty chapter -> visible in chapterGroups when unfiltered
        let added = await vm.addChapter("Series")
        #expect(added)
        #expect(vm.deck.chapters == ["Limits", "Sequences", "Series"])
        #expect(vm.chapterGroups.map(\.title).contains("Series"))

        // Duplicate or empty chapter rejected
        #expect(await vm.addChapter("Series") == false)
        #expect(await vm.addChapter("   ") == false)

        // 2. Rename chapter updates deck.chapters and matching cards
        let renamed = await vm.renameChapter(old: "Limits", new: "Continuity")
        #expect(renamed)
        #expect(vm.deck.chapters == ["Continuity", "Sequences", "Series"])
        #expect(vm.cards.first(where: { $0.id == "c2" })?.topic == "Continuity")

        // 3. Delete chapter keeping cards (moves cards to General "")
        let deletedMove = await vm.deleteChapter("Continuity", deleteCards: false)
        #expect(deletedMove)
        #expect(vm.deck.chapters == ["Sequences", "Series"])
        #expect(vm.cards.first(where: { $0.id == "c2" })?.topic == "")

        // 4. Transfer within same deck to a new chapter
        let sameDeckMoved = await vm.transferCards(cardIds: ["c3"], targetDeckId: "deck-1", targetTopic: "Integrals")
        #expect(sameDeckMoved == 1)
        #expect(vm.cards.first(where: { $0.id == "c3" })?.topic == "Integrals")
        #expect(vm.deck.chapters.contains("Integrals"))

        // 5. Cross-deck transfer removes cards from source VM and records TransferCardsRequest
        vm.selectedCardID = "c1"
        let crossDeckMoved = await vm.transferCards(cardIds: ["c1"], targetDeckId: "deck-2", targetTopic: "Hausdorff")
        #expect(crossDeckMoved == 1)
        #expect(!vm.cards.contains(where: { $0.id == "c1" }))
        #expect(vm.selectedCardID == nil)

        let transferCalls = await mock.transferCalls
        #expect(transferCalls.count == 2)
        #expect(transferCalls[1].targetDeckId == "deck-2")
        #expect(transferCalls[1].targetTopic == "Hausdorff")

        // 6. Delete chapter with deleteCards: true removes cards in that chapter
        let deletedWithCards = await vm.deleteChapter("Integrals", deleteCards: true)
        #expect(deletedWithCards)
        #expect(!vm.cards.contains(where: { $0.id == "c3" }))
    }

    @Test("DeckDetailViewModel sync updates deck and cards in-place and resets cross-deck selection")
    func deckDetailSyncInPlace() {
        let (decks, cards) = sampleData()
        let deck1 = decks[0]
        let deck2 = decks[1]
        let deck1Cards = cards.filter { $0.deckId == deck1.id }
        let deck2Cards = cards.filter { $0.deckId == deck2.id }

        let vm = DeckDetailViewModel(deck: deck1, initialCards: deck1Cards)
        vm.selectedCardID = "c1"
        vm.toggleMultiSelect()
        vm.toggleCardSelection("c2")
        vm.filterType = .theorem
        vm.dueOnly = true

        vm.sync(deck: deck2, cards: deck2Cards)

        #expect(vm.deck.id == "deck-2")
        #expect(vm.cards.map(\.id) == ["c4"])
        #expect(vm.selectedCardID == nil)
        #expect(!vm.isMultiSelectMode)
        #expect(vm.selectedCardIDs.isEmpty)
        #expect(vm.filterType == nil)
        #expect(!vm.dueOnly)
        #expect(vm.isChapterExpanded("Compactness"))
    }

    @Test("LibraryViewModel supports renaming, moving/reordering decks, and chapter structure")
    func libraryRenameReorderAndChapters() async {
        let (decks, cards) = sampleData()
        let mock = MockCoreClient(decks: decks, cards: cards)
        let vm = LibraryViewModel(client: mock)
        await vm.loadAll()

        #expect(vm.chapterNames(for: vm.decks[0]) == ["Limits", "Sequences"])

        let renamed = await vm.renameDeck(id: "deck-1", title: "  Analysis I  ")
        #expect(renamed?.title == "Analysis I")
        #expect(vm.deck(for: "deck-1")?.title == "Analysis I")

        await vm.moveDeck(id: "deck-2", offset: -1)
        #expect(vm.decks.map(\.id) == ["deck-2", "deck-1"])
        let persistedOrder = await mock.decks.map(\.id)
        #expect(persistedOrder == ["deck-2", "deck-1"])

        vm.selection = .library
        #expect(vm.selection == .library)
    }

    @Test("CardDragCoordinator clamps drag within workspace bounds and resolves deck/chapter targets")
    func dragCoordinatorBoundsAndTargets() {
        let (_, cards) = sampleData()
        let card = cards[0] // deck-1
        let coordinator = CardDragCoordinator()
        coordinator.workspaceBounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        coordinator.sidebarDeckFrames = [
            "deck-1": CGRect(x: 16, y: 200, width: 200, height: 32),
            "deck-2": CGRect(x: 16, y: 240, width: 200, height: 32)
        ]
        coordinator.chapterFrames = [
            "Limits": CGRect(x: 280, y: 240, width: 650, height: 140),
            "Sequences": CGRect(x: 280, y: 400, width: 650, height: 140)
        ]
        coordinator.cardFrames = [
            "c2": (chapter: "Limits", index: 0, rect: CGRect(x: 290, y: 280, width: 630, height: 60))
        ]

        // Clamping outside workspace bounds keeps location inside [16..984, 16..684]
        coordinator.updateDrag(card: card, rawLocation: CGPoint(x: -50, y: 900))
        #expect(coordinator.dragLocation == CGPoint(x: 16, y: 684))

        // Dropping onto card row resolves chapter + insertion index before/after midY
        coordinator.updateDrag(card: card, rawLocation: CGPoint(x: 400, y: 295))
        #expect(coordinator.hoveredChapter == "Limits")
        #expect(coordinator.hoveredInsertIndex == 0)
        #expect(coordinator.hoveredDeckId == nil)

        coordinator.updateDrag(card: card, rawLocation: CGPoint(x: 400, y: 330))
        #expect(coordinator.hoveredChapter == "Limits")
        #expect(coordinator.hoveredInsertIndex == 1)

        // Hovering over another sidebar deck resolves cross-deck target (ignores source deck-1)
        coordinator.updateDrag(card: card, rawLocation: CGPoint(x: 100, y: 210))
        #expect(coordinator.hoveredDeckId == nil)
        coordinator.updateDrag(card: card, rawLocation: CGPoint(x: 100, y: 255))
        #expect(coordinator.hoveredDeckId == "deck-2")
        #expect(coordinator.hoveredChapter == nil)

        coordinator.endDrag()
        #expect(coordinator.draggingCard == nil)
        #expect(coordinator.hoveredDeckId == nil)
    }

    @Test("DeckDragCoordinator clamps within Library bounds, swaps live grid order, and resets on end")
    func deckDragCoordinatorBoundsAndLiveOrder() {
        let (decks, _) = sampleData()
        let first = decks[0]
        let second = decks[1]
        let coordinator = DeckDragCoordinator()
        coordinator.libraryBounds = CGRect(x: 248, y: 52, width: 900, height: 680)
        coordinator.deckFrames = [
            first.id: CGRect(x: 272, y: 180, width: 280, height: 170),
            second.id: CGRect(x: 568, y: 180, width: 280, height: 170)
        ]

        // Clamped within [272..1124, 76..708]
        coordinator.updateDrag(
            deck: first,
            currentOrder: [first.id, second.id],
            rawLocation: CGPoint(x: 100, y: 900)
        )
        #expect(coordinator.dragLocation == CGPoint(x: 272, y: 708))
        #expect(coordinator.orderedDeckIds == [first.id, second.id])

        // Dragging over second deck swaps order immediately
        coordinator.updateDrag(
            deck: first,
            currentOrder: [first.id, second.id],
            rawLocation: CGPoint(x: 680, y: 240)
        )
        #expect(coordinator.orderedDeckIds == [second.id, first.id])

        // Re-evaluating inside the same swapped target does not bounce back immediately
        coordinator.updateDrag(
            deck: first,
            currentOrder: [first.id, second.id],
            rawLocation: CGPoint(x: 685, y: 245)
        )
        #expect(coordinator.orderedDeckIds == [second.id, first.id])

        let finalOrder = coordinator.endDrag()
        #expect(finalOrder == [second.id, first.id])
        #expect(coordinator.draggingDeck == nil)
        #expect(coordinator.orderedDeckIds.isEmpty)
    }
}
