import Foundation
import Observation

/// Coordinates a distraction-free study session: step-by-step layer reveals,
/// SM-2 prediction & review submission, tail-only shuffle, audio cues, and crash recovery.
@Observable
@MainActor
public final class StudySessionViewModel {
    public let deck: Deck
    public let deckIds: [String]
    public let deckTitles: [String]
    public let mode: StudyMode
    public let preferences: UserPreferences
    public let startingLives: Int?

    public let sessionId: String
    public let startedAt: String
    public private(set) var originalQueue: [Flashcard]
    public private(set) var queue: [Flashcard]
    public private(set) var currentIndex: Int = 0
    public private(set) var revealedLayersCount: Int = 0
    public private(set) var isAnswerRevealed: Bool = false
    public private(set) var predictions: [Int: IntervalPrediction] = [:]

    public private(set) var reviewedCardIDs: Set<String> = []
    public private(set) var correctCount: Int = 0
    public private(set) var incorrectCount: Int = 0
    public private(set) var livesLeft: Int?
    public private(set) var currentStreak: Int = 0
    public private(set) var bestStreak: Int = 0
    public private(set) var isOutOfLives: Bool = false

    public var isShuffled: Bool = false
    public var soundEnabled: Bool
    public var showTimer: Bool = true
    public var elapsedSeconds: Int = 0

    public private(set) var isCompleted: Bool = false
    public private(set) var isSubmitting: Bool = false
    public var errorMessage: String?

    private let client: (any CoreClientProtocol)?
    private let audioPlayer: any AudioCuePlaying
    private var cardDisplayedAt: Date = Date()
    private var sessionRecordId: String = "sess-\(UUID().uuidString.lowercased())"
    private var undoStack: [UndoSnapshot] = []

    private struct UndoSnapshot {
        let card: Flashcard
        let currentIndex: Int
        let reviewedCardIDs: Set<String>
        let correctCount: Int
        let incorrectCount: Int
        let livesLeft: Int?
        let currentStreak: Int
        let bestStreak: Int
        let isOutOfLives: Bool
        let isCompleted: Bool
        let isGauntletRating: Bool
    }

    public init(
        deck: Deck,
        cards: [Flashcard],
        mode: StudyMode = .standard,
        startingLives: Int? = nil,
        deckIds: [String]? = nil,
        deckTitles: [String]? = nil,
        preferences: UserPreferences = UserPreferences(),
        client: (any CoreClientProtocol)? = nil,
        audioPlayer: any AudioCuePlaying = AudioCueManager.shared,
        restoredState: ActiveSessionState? = nil
    ) {
        self.deck = deck
        self.mode = mode
        self.preferences = preferences
        self.soundEnabled = preferences.soundEnabled
        self.client = client
        self.audioPlayer = audioPlayer

        if let restored = restoredState {
            self.sessionId = restored.sessionId
            self.startedAt = restored.startedAt.isEmpty
                ? ISO8601DateFormatter().string(from: Date())
                : restored.startedAt
            self.deckIds = restored.deckIds.isEmpty ? [deck.id] : restored.deckIds
            self.deckTitles = deckTitles ?? [deck.title]
            self.startingLives = restored.livesLeft ?? startingLives
            self.livesLeft = restored.livesLeft ?? startingLives

            let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            let restoredQueue = restored.cardIds.compactMap { byID[$0] }
            let finalQueue = restoredQueue.isEmpty ? cards : restoredQueue
            self.originalQueue = finalQueue
            self.queue = finalQueue
            self.currentIndex = min(max(0, restored.currentIndex), max(0, finalQueue.count - 1))
            self.reviewedCardIDs = Set(restored.reviewedCardIds)
            self.correctCount = restored.correctCount
            self.incorrectCount = restored.incorrectCount
        } else {
            self.sessionId = "sess-\(UUID().uuidString.prefix(8))"
            self.startedAt = ISO8601DateFormatter().string(from: Date())
            self.deckIds = deckIds ?? [deck.id]
            self.deckTitles = deckTitles ?? [deck.title]
            self.startingLives = (mode == .survival || mode == .mixed) ? startingLives : nil
            self.livesLeft = (mode == .survival || mode == .mixed) ? startingLives : nil
            self.originalQueue = cards
            self.queue = cards
            self.currentIndex = 0
        }

        if let card = currentCard {
            self.revealedLayersCount = preferences.autoRevealSteps ? card.layers.count : 0
        }
        self.cardDisplayedAt = Date()
    }

    // MARK: - Computed Properties

    public var isGauntletMode: Bool {
        mode == .mixed || mode == .survival
    }

    public var currentCard: Flashcard? {
        guard currentIndex >= 0 && currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    public var totalCards: Int {
        queue.count
    }

    public var reviewedCount: Int {
        reviewedCardIDs.count
    }

    public var progressFraction: Double {
        guard !queue.isEmpty else { return 0 }
        if isCompleted { return 1.0 }
        return Double(currentIndex + 1) / Double(queue.count)
    }

    public var accuracyPercent: Int {
        let total = correctCount + incorrectCount
        guard total > 0 else { return 0 }
        return Int((Double(correctCount) / Double(total) * 100.0).rounded())
    }

    public var hasMoreLayersToReveal: Bool {
        guard let card = currentCard else { return false }
        return revealedLayersCount < card.layers.count
    }

    public var formattedElapsedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var canUndo: Bool {
        !undoStack.isEmpty && !isSubmitting
    }

    // MARK: - Lifecycle & Timer

    public func startSession() async {
        guard !queue.isEmpty else {
            isCompleted = true
            return
        }
        resetCardRevealState()
        await loadPredictionsForCurrentCard()
        await persistActiveSession()
    }

    public func tickSecond() {
        guard !isCompleted else { return }
        elapsedSeconds += 1
    }

    // MARK: - Reveal Flow

    /// Reveals the next layer step if remaining, or flips to show the answer.
    public func revealNextStepOrAnswer() {
        guard let card = currentCard, !isAnswerRevealed else { return }
        if revealedLayersCount < card.layers.count {
            revealedLayersCount += 1
            audioPlayer.play(.step, enabled: soundEnabled)
        } else {
            revealAnswer()
        }
    }

    /// Skips remaining layers and reveals the answer immediately.
    public func revealAnswer() {
        guard let card = currentCard, !isAnswerRevealed else { return }
        revealedLayersCount = card.layers.count
        isAnswerRevealed = true
        audioPlayer.play(.flip, enabled: soundEnabled)
    }

    // MARK: - Rating & Completion

    public func submitRating(_ rating: Int) async {
        guard !isGauntletMode else {
            await submitGauntletAnswer(knewIt: rating >= 2)
            return
        }
        guard let card = currentCard, isAnswerRevealed, !isSubmitting else { return }
        guard (1...4).contains(rating) else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        let durationMs = max(0, Int64(Date().timeIntervalSince(cardDisplayedAt) * 1000.0))
        let snapshot = captureUndoSnapshot(card: card, isGauntletRating: false)

        do {
            if let client {
                let updated = try await client.reviewCard(id: card.id, rating: rating, durationMs: durationMs)
                replaceCardInQueues(updated)
            }

            undoStack.append(snapshot)
            reviewedCardIDs.insert(card.id)
            if rating >= 2 {
                correctCount += 1
                audioPlayer.play(.correct, enabled: soundEnabled)
            } else {
                incorrectCount += 1
                audioPlayer.play(.wrong, enabled: soundEnabled)
            }

            if currentIndex + 1 < queue.count {
                currentIndex += 1
                resetCardRevealState()
                await loadPredictionsForCurrentCard()
                await persistActiveSession()
            } else {
                await completeSession()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Binary Gauntlet evaluation (`Missed` vs `Knew It`). Never mutates SM-2 scheduling.
    public func submitGauntletAnswer(knewIt: Bool) async {
        guard isGauntletMode, let card = currentCard, isAnswerRevealed, !isSubmitting else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        undoStack.append(captureUndoSnapshot(card: card, isGauntletRating: true))
        reviewedCardIDs.insert(card.id)
        if knewIt {
            correctCount += 1
            currentStreak += 1
            bestStreak = max(bestStreak, currentStreak)
            audioPlayer.play(.correct, enabled: soundEnabled)
        } else {
            incorrectCount += 1
            currentStreak = 0
            if let currentLives = livesLeft {
                livesLeft = max(0, currentLives - 1)
            }
            audioPlayer.play(.wrong, enabled: soundEnabled)
        }

        if let remaining = livesLeft, remaining == 0 {
            isOutOfLives = true
            await completeSession()
            return
        }

        if currentIndex + 1 < queue.count {
            currentIndex += 1
            resetCardRevealState()
            await persistActiveSession()
        } else {
            await completeSession()
        }
    }

    /// Reverts the most recent rating in this session (including from completion or game-over),
    /// restores backend SM-2 state for standard sessions, and returns to the unrevealed card.
    public func undoLastRating() async {
        guard !isSubmitting, let snapshot = undoStack.last else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            if !snapshot.isGauntletRating, let client {
                let restored = try await client.undoReview(cardID: snapshot.card.id)
                replaceCardInQueues(restored)
            } else {
                replaceCardInQueues(snapshot.card)
            }

            undoStack.removeLast()
            currentIndex = min(max(0, snapshot.currentIndex), max(0, queue.count - 1))
            reviewedCardIDs = snapshot.reviewedCardIDs
            correctCount = snapshot.correctCount
            incorrectCount = snapshot.incorrectCount
            livesLeft = snapshot.livesLeft
            currentStreak = snapshot.currentStreak
            bestStreak = snapshot.bestStreak
            isOutOfLives = snapshot.isOutOfLives
            isCompleted = snapshot.isCompleted

            resetCardRevealState()
            await loadPredictionsForCurrentCard()
            await persistActiveSession()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Navigation & Tail-Only Shuffle

    public func jumpToCard(at index: Int) async {
        guard index >= 0 && index < queue.count, !isCompleted else { return }
        currentIndex = index
        resetCardRevealState()
        await loadPredictionsForCurrentCard()
        await persistActiveSession()
    }

    /// Toggles Fisher-Yates shuffle on `queue[currentIndex...]` only, preserving `queue[..<currentIndex]`.
    /// Toggling off restores the remaining tail cards to their `originalQueue` order.
    public func toggleShuffle() async {
        guard !isCompleted, currentIndex < queue.count else { return }
        let head = Array(queue.prefix(currentIndex))
        let headIDs = Set(head.map(\.id))

        if !isShuffled {
            var tail = Array(queue.dropFirst(currentIndex))
            if tail.count > 1 {
                for i in stride(from: tail.count - 1, through: 1, by: -1) {
                    let j = Int.random(in: 0...i)
                    if i != j {
                        tail.swapAt(i, j)
                    }
                }
            }
            queue = head + tail
            isShuffled = true
        } else {
            let restoredTail = originalQueue.filter { !headIDs.contains($0.id) }
            queue = head + restoredTail
            isShuffled = false
        }

        resetCardRevealState()
        await loadPredictionsForCurrentCard()
        await persistActiveSession()
    }

    public func restart() async {
        queue = originalQueue
        currentIndex = 0
        reviewedCardIDs = []
        correctCount = 0
        incorrectCount = 0
        livesLeft = startingLives
        currentStreak = 0
        bestStreak = 0
        isOutOfLives = false
        elapsedSeconds = 0
        isShuffled = false
        isCompleted = false
        sessionRecordId = "sess-\(UUID().uuidString.lowercased())"
        undoStack.removeAll()
        errorMessage = nil
        resetCardRevealState()
        await loadPredictionsForCurrentCard()
        await persistActiveSession()
    }

    // MARK: - Interruption Actions

    /// Saves a partial `StudySessionRecord` (when `reviewedCount > 0`), clears active recovery state,
    /// and transitions to the completion summary.
    public func finishEarly() async {
        await completeSession()
    }

    /// Persists the current `ActiveSessionState` so the user can resume later from the library.
    public func pauseAndSaveForLater() async {
        await persistActiveSession()
    }

    /// Clears `ActiveSessionState` without saving a completed session record.
    public func discardSession() async {
        guard let client else { return }
        try? await client.clearActiveSession()
    }

    // MARK: - Private Helpers

    private func captureUndoSnapshot(card: Flashcard, isGauntletRating: Bool) -> UndoSnapshot {
        UndoSnapshot(
            card: card,
            currentIndex: currentIndex,
            reviewedCardIDs: reviewedCardIDs,
            correctCount: correctCount,
            incorrectCount: incorrectCount,
            livesLeft: livesLeft,
            currentStreak: currentStreak,
            bestStreak: bestStreak,
            isOutOfLives: isOutOfLives,
            isCompleted: isCompleted,
            isGauntletRating: isGauntletRating
        )
    }

    private func resetCardRevealState() {
        isAnswerRevealed = false
        if let card = currentCard {
            revealedLayersCount = preferences.autoRevealSteps ? card.layers.count : 0
        } else {
            revealedLayersCount = 0
        }
        cardDisplayedAt = Date()
    }

    private func replaceCardInQueues(_ updated: Flashcard) {
        if let idx = queue.firstIndex(where: { $0.id == updated.id }) {
            queue[idx] = updated
        }
        if let idx = originalQueue.firstIndex(where: { $0.id == updated.id }) {
            originalQueue[idx] = updated
        }
    }

    private func loadPredictionsForCurrentCard() async {
        guard !isGauntletMode, let card = currentCard, let client else {
            predictions = [:]
            return
        }
        do {
            let raw = try await client.predictCard(id: card.id)
            var mapped: [Int: IntervalPrediction] = [:]
            for (k, v) in raw {
                if let rating = Int(k) {
                    mapped[rating] = v
                }
            }
            predictions = mapped
        } catch {
            predictions = [:]
        }
    }

    private func persistActiveSession() async {
        guard let client, !isCompleted, !queue.isEmpty else { return }
        let snapshot = ActiveSessionState(
            sessionId: sessionId,
            deckId: deckIds.count == 1 ? deckIds.first : nil,
            deckIds: deckIds,
            mode: mode,
            currentIndex: currentIndex,
            cardIds: queue.map(\.id),
            reviewedCardIds: Array(reviewedCardIDs),
            correctCount: correctCount,
            incorrectCount: incorrectCount,
            livesLeft: livesLeft,
            startedAt: startedAt
        )
        _ = try? await client.saveActiveSession(snapshot)
    }

    private func completeSession() async {
        isCompleted = true
        audioPlayer.play(.chime, enabled: soundEnabled)

        guard let client else { return }
        if reviewedCount > 0 {
            let record = StudySessionRecord(
                id: sessionRecordId,
                mode: mode,
                deckIds: deckIds,
                deckTitles: deckTitles,
                cardsReviewed: reviewedCount,
                correctCount: correctCount,
                incorrectCount: incorrectCount,
                livesLeft: livesLeft,
                durationSeconds: elapsedSeconds
            )
            _ = try? await client.createSession(record)
        }
        try? await client.clearActiveSession()
    }
}
