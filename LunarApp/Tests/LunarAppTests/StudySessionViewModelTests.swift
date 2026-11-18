import Foundation
import Testing
@testable import LunarApp

private final class SpyAudioPlayer: AudioCuePlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(AudioCue, Bool)] = []

    func play(_ cue: AudioCue, enabled: Bool) {
        lock.lock()
        recorded.append((cue, enabled))
        lock.unlock()
    }

    var cues: [AudioCue] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter(\.1).map(\.0)
    }
}

private actor StudyMockClient: CoreClientProtocol {
    var cards: [Flashcard]
    var savedActiveStates: [ActiveSessionState] = []
    var clearedActiveCount = 0
    var createdSessions: [StudySessionRecord] = []
    var reviewCalls: [(id: String, rating: Int)] = []
    var undoCalls: [String] = []
    var reviewHistoryStack: [String: [Flashcard]] = [:]
    var shouldFailUndo = false

    init(cards: [Flashcard]) {
        self.cards = cards
    }

    func setShouldFailUndo(_ fail: Bool) {
        shouldFailUndo = fail
    }

    func health() async throws -> Bool { true }
    func listDecks() async throws -> [Deck] { [] }
    func createDeck(_ deck: Deck) async throws -> Deck { deck }
    func updateDeck(id: String, _ deck: Deck) async throws -> Deck { deck }
    func deleteDeck(id: String) async throws {}
    func reorderDecks(deckIds: [String]) async throws {}
    func listDeckCards(deckId: String) async throws -> [Flashcard] { cards }
    func listCards(deckId: String?) async throws -> [Flashcard] { cards }
    func createCard(_ card: Flashcard) async throws -> Flashcard { card }
    func updateCard(id: String, _ card: Flashcard) async throws -> Flashcard { card }
    func deleteCard(id: String) async throws {}
    func reorderCards(deckId: String, cardIds: [String]) async throws {}

    func reviewCard(id: String, rating: Int, durationMs: Int64?) async throws -> Flashcard {
        reviewCalls.append((id: id, rating: rating))
        let idx = cards.firstIndex { $0.id == id }!
        var card = cards[idx]
        reviewHistoryStack[id, default: []].append(card)
        card.totalReviews += 1
        if rating >= 2 {
            card.correctCount += 1
            card.repetition += 1
            card.intervalDays = rating == 4 ? 4 : 1
        } else {
            card.incorrectCount += 1
            card.repetition = 0
            card.intervalDays = 1
        }
        cards[idx] = card
        return card
    }

    func undoReview(cardID: String) async throws -> Flashcard {
        if shouldFailUndo {
            throw CoreClientError.serverError(statusCode: 409, message: "No review to undo")
        }
        undoCalls.append(cardID)
        guard var stack = reviewHistoryStack[cardID], let previous = stack.popLast() else {
            throw CoreClientError.serverError(statusCode: 409, message: "No review to undo")
        }
        reviewHistoryStack[cardID] = stack
        if let idx = cards.firstIndex(where: { $0.id == cardID }) {
            cards[idx] = previous
        }
        return previous
    }

    func predictCard(id: String) async throws -> [String: IntervalPrediction] {
        [
            "1": IntervalPrediction(days: 1, label: "1d"),
            "2": IntervalPrediction(days: 1, label: "1d"),
            "3": IntervalPrediction(days: 6, label: "6d"),
            "4": IntervalPrediction(days: 10, label: "10d")
        ]
    }

    func listSessions() async throws -> [StudySessionRecord] { createdSessions }

    func createSession(_ session: StudySessionRecord) async throws -> StudySessionRecord {
        createdSessions.append(session)
        return session
    }

    func getActiveSession() async throws -> ActiveSessionState? { savedActiveStates.last }

    func saveActiveSession(_ state: ActiveSessionState) async throws -> ActiveSessionState {
        savedActiveStates.append(state)
        return state
    }

    func clearActiveSession() async throws {
        clearedActiveCount += 1
    }

    func getPreferences() async throws -> UserPreferences { UserPreferences() }
    func updatePreferences(_ preferences: UserPreferences) async throws -> UserPreferences { preferences }

    func exportDeck(deckId: String, format: IOFormat) async throws -> ExportResult {
        ExportResult(filename: "export.\(format.fileExtension)", content: "", mimeType: "text/plain")
    }

    func importCards(_ request: ImportRequest) async throws -> ImportResult {
        ImportResult(deck: Deck(title: "Imported"), importedCount: 0, cards: [])
    }

    func getStats(days: Int) async throws -> StatsSummary {
        StatsSummary()
    }

    @discardableResult
    func transferCards(cardIds: [String], targetDeckId: String, targetTopic: String?, targetIndex: Int?) async throws -> Int {
        cardIds.count
    }
}

@Suite("StudySessionViewModel Reveal, Shuffle, SM-2 & Crash Recovery")
@MainActor
struct StudySessionViewModelTests {
    private func sampleDeckAndCards() -> (Deck, [Flashcard]) {
        let deck = Deck(id: "deck-study", title: "Real Analysis")
        let cards = [
            Flashcard(
                id: "c1",
                deckId: "deck-study",
                topic: "Limits",
                order: 0,
                cardType: .definition,
                front: "Limit definition",
                back: "Epsilon-delta",
                layers: [
                    CardLayer(id: "l1", title: "Step 1", content: "Quantify epsilon"),
                    CardLayer(id: "l2", title: "Step 2", content: "Choose delta")
                ]
            ),
            Flashcard(
                id: "c2",
                deckId: "deck-study",
                topic: "Sequences",
                order: 1,
                cardType: .theorem,
                front: "Bolzano-Weierstrass",
                back: "Convergent subsequence",
                layers: [
                    CardLayer(id: "l3", title: "Hint", content: "Bisect interval")
                ]
            ),
            Flashcard(
                id: "c3",
                deckId: "deck-study",
                topic: "Series",
                order: 2,
                cardType: .example,
                front: "Harmonic series",
                back: "Diverges",
                layers: []
            ),
            Flashcard(
                id: "c4",
                deckId: "deck-study",
                topic: "Series",
                order: 3,
                cardType: .theorem,
                front: "Alternating series test",
                back: "Leibniz criterion",
                layers: []
            )
        ]
        return (deck, cards)
    }

    @Test("Step-by-step reveal, skip-to-answer, and autoRevealSteps behavior")
    func revealFlowAndAutoReveal() async {
        let (deck, cards) = sampleDeckAndCards()
        let audio = SpyAudioPlayer()
        let mock = StudyMockClient(cards: cards)

        let vm = StudySessionViewModel(
            deck: deck,
            cards: cards,
            preferences: UserPreferences(soundEnabled: true, autoRevealSteps: false),
            client: mock,
            audioPlayer: audio
        )
        await vm.startSession()

        #expect(vm.revealedLayersCount == 0)
        #expect(!vm.isAnswerRevealed)
        #expect(vm.predictions[3]?.label == "6d")

        vm.revealNextStepOrAnswer()
        #expect(vm.revealedLayersCount == 1)
        #expect(!vm.isAnswerRevealed)

        vm.revealNextStepOrAnswer()
        #expect(vm.revealedLayersCount == 2)
        #expect(!vm.isAnswerRevealed)

        vm.revealNextStepOrAnswer()
        #expect(vm.isAnswerRevealed)
        #expect(audio.cues == [.step, .step, .flip])

        // autoRevealSteps = true + skip-to-answer on second card
        let autoVM = StudySessionViewModel(
            deck: deck,
            cards: cards,
            preferences: UserPreferences(soundEnabled: true, autoRevealSteps: true),
            client: mock,
            audioPlayer: SpyAudioPlayer()
        )
        await autoVM.startSession()
        #expect(autoVM.revealedLayersCount == 2)
        autoVM.revealAnswer()
        #expect(autoVM.isAnswerRevealed)
    }

    @Test("Tail-only shuffle preserves reviewed prefix and unshuffle restores original tail order")
    func tailOnlyShuffleAndUnshuffle() async {
        let (deck, cards) = sampleDeckAndCards()
        let mock = StudyMockClient(cards: cards)
        let vm = StudySessionViewModel(
            deck: deck,
            cards: cards,
            client: mock,
            audioPlayer: SpyAudioPlayer()
        )
        await vm.startSession()

        // Complete c1 so currentIndex moves to 1 (c2, c3, c4 remain in tail)
        vm.revealAnswer()
        await vm.submitRating(3)
        #expect(vm.currentIndex == 1)
        #expect(vm.queue[0].id == "c1")

        await vm.toggleShuffle()
        #expect(vm.isShuffled)
        #expect(vm.queue[0].id == "c1")
        #expect(Set(vm.queue.dropFirst(1).map(\.id)) == Set(["c2", "c3", "c4"]))

        // Unshuffle restores c2, c3, c4 in exact original order
        await vm.toggleShuffle()
        #expect(!vm.isShuffled)
        #expect(vm.queue.map(\.id) == ["c1", "c2", "c3", "c4"])
    }

    @Test("SM-2 submission, session completion, and active-session crash recovery")
    func sm2SubmissionAndCrashRecovery() async {
        let (deck, cards) = sampleDeckAndCards()
        let subset = Array(cards.prefix(2))
        let audio = SpyAudioPlayer()
        let mock = StudyMockClient(cards: subset)

        let vm = StudySessionViewModel(
            deck: deck,
            cards: subset,
            preferences: UserPreferences(soundEnabled: true),
            client: mock,
            audioPlayer: audio
        )
        await vm.startSession()
        #expect(await mock.savedActiveStates.count == 1)

        vm.revealAnswer()
        await vm.submitRating(1) // Again -> incorrect
        #expect(vm.incorrectCount == 1)
        #expect(vm.currentIndex == 1)
        #expect(await mock.savedActiveStates.count == 2)

        vm.revealAnswer()
        await vm.submitRating(4) // Easy -> correct + finishes session
        #expect(vm.correctCount == 1)
        #expect(vm.isCompleted)
        #expect(vm.accuracyPercent == 50)
        #expect(await mock.createdSessions.count == 1)
        #expect(await mock.clearedActiveCount == 1)
        #expect(audio.cues.contains(.wrong))
        #expect(audio.cues.contains(.correct))
        #expect(audio.cues.contains(.chime))

        // Crash recovery restore
        let snapshot = ActiveSessionState(
            sessionId: "sess-crash",
            deckId: deck.id,
            deckIds: [deck.id],
            mode: .standard,
            currentIndex: 2,
            cardIds: ["c4", "c3", "c2", "c1"],
            reviewedCardIds: ["c4", "c3"],
            correctCount: 2,
            incorrectCount: 0,
            livesLeft: nil,
            startedAt: "2026-11-17T10:00:00Z"
        )
        let recoveredVM = StudySessionViewModel(
            deck: deck,
            cards: cards,
            client: mock,
            audioPlayer: SpyAudioPlayer(),
            restoredState: snapshot
        )
        #expect(recoveredVM.sessionId == "sess-crash")
        #expect(recoveredVM.currentIndex == 2)
        #expect(recoveredVM.currentCard?.id == "c2")
        #expect(recoveredVM.reviewedCount == 2)
        #expect(recoveredVM.correctCount == 2)

        // Pause keeps active session; discard clears it
        await recoveredVM.pauseAndSaveForLater()
        #expect(await mock.savedActiveStates.last?.sessionId == "sess-crash")
        await recoveredVM.discardSession()
        #expect(await mock.clearedActiveCount == 2)
    }

    @Test("Undo stack reverts ratings sequentially including from completion, syncs persistence, and guards empty stack")
    func standardUndoStackAndEmptyGuard() async {
        let (deck, cards) = sampleDeckAndCards()
        let subset = Array(cards.prefix(2))
        let mock = StudyMockClient(cards: subset)

        let vm = StudySessionViewModel(
            deck: deck,
            cards: subset,
            preferences: UserPreferences(soundEnabled: false, autoRevealSteps: false),
            client: mock,
            audioPlayer: SpyAudioPlayer()
        )
        await vm.startSession()

        // Empty stack guard
        #expect(!vm.canUndo)
        await vm.undoLastRating()
        #expect(await mock.undoCalls.isEmpty)

        // Rate c1 (Again) -> moves to c2
        vm.revealAnswer()
        await vm.submitRating(1)
        #expect(vm.currentIndex == 1)
        #expect(vm.incorrectCount == 1)
        #expect(vm.queue[0].totalReviews == 1)
        #expect(vm.canUndo)

        // Rate c2 (Easy) -> completes session
        vm.revealAnswer()
        await vm.submitRating(4)
        #expect(vm.isCompleted)
        #expect(vm.correctCount == 1)
        #expect(vm.incorrectCount == 1)
        #expect(vm.reviewedCount == 2)

        // Undo from completion summary restores c2 unrevealed and re-saves active session
        await vm.undoLastRating()
        #expect(!vm.isCompleted)
        #expect(vm.currentIndex == 1)
        #expect(vm.currentCard?.id == "c2")
        #expect(!vm.isAnswerRevealed)
        #expect(vm.revealedLayersCount == 0)
        #expect(vm.correctCount == 0)
        #expect(vm.incorrectCount == 1)
        #expect(vm.reviewedCardIDs == Set(["c1"]))
        #expect(vm.queue[1].totalReviews == 0)
        #expect(await mock.undoCalls == ["c2"])
        #expect(await mock.savedActiveStates.last?.currentIndex == 1)
        #expect(await mock.savedActiveStates.last?.reviewedCardIds == ["c1"])

        // Undo c1 -> returns to c1 unrevealed, empty undo stack
        await vm.undoLastRating()
        #expect(vm.currentIndex == 0)
        #expect(vm.currentCard?.id == "c1")
        #expect(!vm.isAnswerRevealed)
        #expect(vm.correctCount == 0)
        #expect(vm.incorrectCount == 0)
        #expect(vm.reviewedCardIDs.isEmpty)
        #expect(vm.queue[0].totalReviews == 0)
        #expect(!vm.canUndo)
        #expect(await mock.undoCalls == ["c2", "c1"])

        // Second empty guard after draining stack
        await vm.undoLastRating()
        #expect(await mock.undoCalls.count == 2)
    }

    @Test("Undo restores lost life and exits game-over in Gauntlet survival without calling backend undo")
    func gauntletWrongRatingLifeRestoration() async {
        let (deck, cards) = sampleDeckAndCards()
        let subset = Array(cards.prefix(2))
        let mock = StudyMockClient(cards: subset)

        let vm = StudySessionViewModel(
            deck: deck,
            cards: subset,
            mode: .survival,
            startingLives: 1,
            client: mock,
            audioPlayer: SpyAudioPlayer()
        )
        await vm.startSession()
        #expect(vm.livesLeft == 1)

        vm.revealAnswer()
        await vm.submitGauntletAnswer(knewIt: false)
        #expect(vm.livesLeft == 0)
        #expect(vm.isOutOfLives)
        #expect(vm.isCompleted)
        #expect(vm.incorrectCount == 1)
        #expect(vm.canUndo)

        await vm.undoLastRating()
        #expect(!vm.isCompleted)
        #expect(!vm.isOutOfLives)
        #expect(vm.livesLeft == 1)
        #expect(vm.incorrectCount == 0)
        #expect(vm.currentIndex == 0)
        #expect(vm.currentCard?.id == "c1")
        #expect(!vm.isAnswerRevealed)
        #expect(!vm.canUndo)
        #expect(await mock.undoCalls.isEmpty)
        #expect(await mock.savedActiveStates.last?.livesLeft == 1)
    }

    @Test("Backend undo failure preserves undo stack and exposes errorMessage")
    func undoFailurePreservesStack() async {
        let (deck, cards) = sampleDeckAndCards()
        let mock = StudyMockClient(cards: Array(cards.prefix(2)))

        let vm = StudySessionViewModel(
            deck: deck,
            cards: Array(cards.prefix(2)),
            client: mock,
            audioPlayer: SpyAudioPlayer()
        )
        await vm.startSession()

        vm.revealAnswer()
        await vm.submitRating(3)
        #expect(vm.currentIndex == 1)
        #expect(vm.correctCount == 1)

        await mock.setShouldFailUndo(true)
        await vm.undoLastRating()

        #expect(vm.errorMessage != nil)
        #expect(vm.canUndo)
        #expect(vm.currentIndex == 1)
        #expect(vm.correctCount == 1)
    }
}
