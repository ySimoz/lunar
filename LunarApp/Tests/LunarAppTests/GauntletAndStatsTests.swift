import Foundation
import Testing
@testable import LunarApp

private actor GauntletStatsMockClient: CoreClientProtocol {
    var reviewCallCount = 0
    var predictCallCount = 0
    var createdSessions: [StudySessionRecord] = []
    var clearedActiveCount = 0
    var stubSummary: StatsSummary
    var requestedDays: [Int] = []

    init(stubSummary: StatsSummary = StatsSummary()) {
        self.stubSummary = stubSummary
    }

    func health() async throws -> Bool { true }
    func listDecks() async throws -> [Deck] { [] }
    func createDeck(_ deck: Deck) async throws -> Deck { deck }
    func updateDeck(id: String, _ deck: Deck) async throws -> Deck { deck }
    func deleteDeck(id: String) async throws {}
    func reorderDecks(deckIds: [String]) async throws {}
    func listDeckCards(deckId: String) async throws -> [Flashcard] { [] }
    func listCards(deckId: String?) async throws -> [Flashcard] { [] }
    func createCard(_ card: Flashcard) async throws -> Flashcard { card }
    func updateCard(id: String, _ card: Flashcard) async throws -> Flashcard { card }
    func deleteCard(id: String) async throws {}
    func reorderCards(deckId: String, cardIds: [String]) async throws {}

    func reviewCard(id: String, rating: Int, durationMs: Int64?) async throws -> Flashcard {
        reviewCallCount += 1
        return Flashcard(id: id, deckId: "d1", front: "F", back: "B")
    }

    func predictCard(id: String) async throws -> [String: IntervalPrediction] {
        predictCallCount += 1
        return [:]
    }

    func listSessions() async throws -> [StudySessionRecord] { createdSessions }

    func createSession(_ session: StudySessionRecord) async throws -> StudySessionRecord {
        createdSessions.append(session)
        return session
    }

    func getActiveSession() async throws -> ActiveSessionState? { nil }
    func saveActiveSession(_ state: ActiveSessionState) async throws -> ActiveSessionState { state }

    func clearActiveSession() async throws {
        clearedActiveCount += 1
    }

    func getPreferences() async throws -> UserPreferences { UserPreferences() }
    func updatePreferences(_ preferences: UserPreferences) async throws -> UserPreferences { preferences }

    func exportDeck(deckId: String, format: IOFormat) async throws -> ExportResult {
        ExportResult(filename: "d.json", content: "{}", mimeType: "application/json")
    }

    func importCards(_ request: ImportRequest) async throws -> ImportResult {
        ImportResult(deck: Deck(title: "D"), importedCount: 0, cards: [])
    }

    func getStats(days: Int) async throws -> StatsSummary {
        requestedDays.append(days)
        return stubSummary
    }

    @discardableResult
    func transferCards(cardIds: [String], targetDeckId: String, targetTopic: String?, targetIndex: Int?) async throws -> Int {
        cardIds.count
    }
}

@Suite("Gauntlet Survival Mode & Analytics Stats")
@MainActor
struct GauntletAndStatsTests {
    @Test("StatsSummary decodes exact Go internal/stats JSON payload")
    func statsSummaryDecodesGoJSON() throws {
        let goJSON = """
        {
          "totalCards": 16,
          "dueCards": 5,
          "totalReviews": 42,
          "totalCorrect": 36,
          "retentionRate": 86,
          "totalStudySeconds": 940,
          "currentStreakDays": 4,
          "longestStreakDays": 9,
          "masteryPipeline": {
            "newCount": 3,
            "learningCount": 4,
            "reviewCount": 5,
            "masteredCount": 4,
            "masteredPercent": 25
          },
          "deckBreakdown": [
            {
              "deckId": "deck-ra",
              "title": "Real Analysis",
              "totalCards": 6,
              "dueCards": 2,
              "masteredCards": 2,
              "masteredPercent": 33,
              "averageEase": 2.48
            }
          ],
          "dailyActivity": [
            {
              "date": "2026-11-17",
              "reviews": 8,
              "correct": 7,
              "studySeconds": 240
            }
          ]
        }
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(StatsSummary.self, from: goJSON)
        #expect(summary.totalCards == 16)
        #expect(summary.dueCards == 5)
        #expect(summary.retentionRate == 86)
        #expect(summary.currentStreakDays == 4)
        #expect(summary.longestStreakDays == 9)
        #expect(summary.masteryPipeline.masteredCount == 4)
        #expect(summary.masteryPipeline.masteredPercent == 25)
        #expect(summary.deckBreakdown.first?.deckId == "deck-ra")
        #expect(summary.deckBreakdown.first?.averageEase == 2.48)
        #expect(summary.dailyActivity.first?.date == "2026-11-17")
        #expect(summary.dailyActivity.first?.parsedDate != nil)
    }

    @Test("GauntletSetupViewModel pools across selected decks and slices by runLength")
    func gauntletPoolingAndSlicing() {
        let d1 = Deck(id: "d1", title: "Analysis", cardCount: 2)
        let d2 = Deck(id: "d2", title: "Algebra", cardCount: 2)
        let cardsByDeck: [String: [Flashcard]] = [
            "d1": [
                Flashcard(id: "c1", deckId: "d1", front: "F1", back: "B1"),
                Flashcard(id: "c2", deckId: "d1", front: "F2", back: "B2")
            ],
            "d2": [
                Flashcard(id: "c3", deckId: "d2", front: "F3", back: "B3"),
                Flashcard(id: "c4", deckId: "d2", front: "F4", back: "B4")
            ]
        ]

        let setup = GauntletSetupViewModel(decks: [d1, d2], defaultLives: 3)
        #expect(setup.livesChoice == .three)
        #expect(setup.pooledCardsCount(cardsByDeck: cardsByDeck) == 4)

        setup.toggleDeck("d2")
        #expect(setup.pooledCardsCount(cardsByDeck: cardsByDeck) == 2)

        setup.selectAll(decks: [d1, d2])
        let (_, sliced) = GauntletSetupViewModel.buildGauntletPool(
            decks: [d1, d2],
            cardsByDeck: cardsByDeck,
            selectedDeckIDs: setup.selectedDeckIDs,
            runLength: .ten,
            shuffle: false
        )
        #expect(sliced.count == 4)

        setup.livesChoice = .unlimited
        let unlimitedReq = setup.buildLaunchRequest(decks: [d1, d2], cardsByDeck: cardsByDeck)
        #expect(unlimitedReq?.mode == .mixed)
        #expect(unlimitedReq?.startingLives == nil)
        #expect(unlimitedReq?.deckIds?.count == 2)
    }

    @Test("Gauntlet survival depletes lives, records streak & session, and never calls reviewCard")
    func gauntletLivesDepletionAndNoSM2Invariant() async {
        let deck = Deck(id: "d1", title: "Gauntlet")
        let cards = [
            Flashcard(id: "c1", deckId: "d1", front: "F1", back: "B1"),
            Flashcard(id: "c2", deckId: "d1", front: "F2", back: "B2"),
            Flashcard(id: "c3", deckId: "d1", front: "F3", back: "B3")
        ]
        let mock = GauntletStatsMockClient()

        let vm = StudySessionViewModel(
            deck: deck,
            cards: cards,
            mode: .survival,
            startingLives: 2,
            deckIds: ["d1"],
            deckTitles: ["Gauntlet"],
            client: mock
        )
        await vm.startSession()
        #expect(vm.isGauntletMode)
        #expect(vm.livesLeft == 2)
        #expect(await mock.predictCallCount == 0)

        // Knew It -> streak 1, lives still 2
        vm.revealAnswer()
        await vm.submitGauntletAnswer(knewIt: true)
        #expect(vm.currentStreak == 1)
        #expect(vm.bestStreak == 1)
        #expect(vm.livesLeft == 2)
        #expect(!vm.isCompleted)

        // Missed -> streak 0, lives 1
        vm.revealAnswer()
        await vm.submitGauntletAnswer(knewIt: false)
        #expect(vm.currentStreak == 0)
        #expect(vm.livesLeft == 1)
        #expect(!vm.isCompleted)

        // Missed -> lives 0, Out of Lives
        vm.revealAnswer()
        await vm.submitGauntletAnswer(knewIt: false)
        #expect(vm.livesLeft == 0)
        #expect(vm.isOutOfLives)
        #expect(vm.isCompleted)

        // Strict no-SM2-mutation invariant
        #expect(await mock.reviewCallCount == 0)
        #expect(await mock.predictCallCount == 0)
        let savedSessions = await mock.createdSessions
        #expect(savedSessions.count == 1)
        #expect(savedSessions[0].mode == .survival)
        #expect(savedSessions[0].livesLeft == 0)
        #expect(savedSessions[0].cardsReviewed == 3)
    }

    @Test("StatsViewModel loads stats and filters Card Inspector (All / Due / Low Ease)")
    func statsViewModelFilteringAndLoading() async {
        let expected = StatsSummary(totalCards: 3, dueCards: 1, retentionRate: 90, currentStreakDays: 2)
        let mock = GauntletStatsMockClient(stubSummary: expected)
        let vm = StatsViewModel(client: mock)
        vm.daysWindow = 14
        await vm.load()

        #expect(vm.summary == expected)
        #expect(await mock.requestedDays == [14])

        let cards = [
            Flashcard(
                id: "c-due",
                deckId: "d1",
                topic: "Limits",
                front: "Limit problem",
                back: "B1",
                easeFactor: 2.5,
                nextReviewDate: "2020-01-01T00:00:00Z",
                totalReviews: 0
            ),
            Flashcard(
                id: "c-low-ease",
                deckId: "d1",
                topic: "Topology",
                front: "Compactness",
                back: "B2",
                easeFactor: 1.5,
                nextReviewDate: "2099-01-01T00:00:00Z",
                totalReviews: 4
            ),
            Flashcard(
                id: "c-healthy",
                deckId: "d1",
                topic: "Algebra",
                front: "Group axiom",
                back: "B3",
                easeFactor: 2.7,
                nextReviewDate: "2099-01-01T00:00:00Z",
                totalReviews: 3
            )
        ]

        #expect(StatsViewModel.filterCards(cards, filter: .all, query: "").count == 3)
        #expect(StatsViewModel.filterCards(cards, filter: .due, query: "").map(\.id) == ["c-due"])
        #expect(StatsViewModel.filterCards(cards, filter: .lowEase, query: "").map(\.id) == ["c-low-ease"])
        #expect(StatsViewModel.filterCards(cards, filter: .all, query: "Compactness").map(\.id) == ["c-low-ease"])
    }
}
