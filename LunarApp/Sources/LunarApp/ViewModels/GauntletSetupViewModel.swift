import Foundation
import Observation

/// Available starting-lives options for Gauntlet mode.
public enum GauntletLivesChoice: Hashable, CaseIterable, Identifiable, Sendable {
    case one
    case three
    case five
    case ten
    case unlimited

    public var id: String { label }

    public var livesCount: Int? {
        switch self {
        case .one: 1
        case .three: 3
        case .five: 5
        case .ten: 10
        case .unlimited: nil
        }
    }

    public var label: String {
        switch self {
        case .one: "1"
        case .three: "3"
        case .five: "5"
        case .ten: "10"
        case .unlimited: "Unlimited"
        }
    }

    public static func fromDefaultLives(_ count: Int) -> GauntletLivesChoice {
        switch count {
        case ...0: .unlimited
        case 1: .one
        case 2...4: .three
        case 5...7: .five
        default: .ten
        }
    }
}

/// Available card-count limits for a Gauntlet run.
public enum GauntletRunLength: Hashable, CaseIterable, Identifiable, Sendable {
    case ten
    case twentyFive
    case fifty
    case all

    public var id: String { label }

    public var maxCount: Int? {
        switch self {
        case .ten: 10
        case .twentyFive: 25
        case .fifty: 50
        case .all: nil
        }
    }

    public var label: String {
        switch self {
        case .ten: "10"
        case .twentyFive: "25"
        case .fifty: "50"
        case .all: "All"
        }
    }
}

/// Manages deck pooling, lives/run-length selection, and recent-run history for Gauntlet mode.
@Observable
@MainActor
public final class GauntletSetupViewModel {
    public var selectedDeckIDs: Set<String>
    public var livesChoice: GauntletLivesChoice
    public var runLength: GauntletRunLength = .twentyFive

    public init(decks: [Deck] = [], defaultLives: Int = 3) {
        self.selectedDeckIDs = Set(decks.filter { $0.cardCount > 0 }.map(\.id))
        self.livesChoice = GauntletLivesChoice.fromDefaultLives(defaultLives)
    }

    public func syncDecks(_ decks: [Deck]) {
        let validIDs = Set(decks.map(\.id))
        selectedDeckIDs = selectedDeckIDs.intersection(validIDs)
        if selectedDeckIDs.isEmpty {
            selectedDeckIDs = Set(decks.filter { $0.cardCount > 0 }.map(\.id))
        }
    }

    public func selectAll(decks: [Deck]) {
        selectedDeckIDs = Set(decks.filter { $0.cardCount > 0 }.map(\.id))
    }

    public func resetSelection() {
        selectedDeckIDs.removeAll()
    }

    public func toggleDeck(_ deckId: String) {
        if selectedDeckIDs.contains(deckId) {
            selectedDeckIDs.remove(deckId)
        } else {
            selectedDeckIDs.insert(deckId)
        }
    }

    public func pooledCardsCount(cardsByDeck: [String: [Flashcard]]) -> Int {
        selectedDeckIDs.reduce(0) { $0 + (cardsByDeck[$1]?.count ?? 0) }
    }

    public func effectiveRunCount(cardsByDeck: [String: [Flashcard]]) -> Int {
        let pooled = pooledCardsCount(cardsByDeck: cardsByDeck)
        if let maxCount = runLength.maxCount {
            return min(pooled, maxCount)
        }
        return pooled
    }

    public nonisolated static func buildGauntletPool(
        decks: [Deck],
        cardsByDeck: [String: [Flashcard]],
        selectedDeckIDs: Set<String>,
        runLength: GauntletRunLength,
        shuffle: Bool = true
    ) -> (selectedDecks: [Deck], cards: [Flashcard]) {
        let chosenDecks = decks.filter { selectedDeckIDs.contains($0.id) }
        var pool = chosenDecks.flatMap { cardsByDeck[$0.id] ?? [] }
        if shuffle && pool.count > 1 {
            pool.shuffle()
        }
        if let limit = runLength.maxCount, pool.count > limit {
            pool = Array(pool.prefix(limit))
        }
        return (chosenDecks, pool)
    }

    public func buildLaunchRequest(
        decks: [Deck],
        cardsByDeck: [String: [Flashcard]]
    ) -> StudyLaunchRequest? {
        let (chosenDecks, pool) = Self.buildGauntletPool(
            decks: decks,
            cardsByDeck: cardsByDeck,
            selectedDeckIDs: selectedDeckIDs,
            runLength: runLength,
            shuffle: true
        )
        guard !chosenDecks.isEmpty, !pool.isEmpty else { return nil }

        let mode: StudyMode = livesChoice.livesCount == nil ? .mixed : .survival
        let displayTitle = chosenDecks.count == 1
            ? chosenDecks[0].title
            : "Gauntlet (\(chosenDecks.count) decks)"

        let syntheticDeck = Deck(
            id: chosenDecks[0].id,
            title: displayTitle,
            cardCount: pool.count
        )

        return StudyLaunchRequest(
            deck: syntheticDeck,
            cards: pool,
            mode: mode,
            startingLives: livesChoice.livesCount,
            deckIds: chosenDecks.map(\.id),
            deckTitles: chosenDecks.map(\.title)
        )
    }

    public nonisolated static func recentGauntletRuns(from sessions: [StudySessionRecord]) -> [StudySessionRecord] {
        sessions.filter { $0.mode == .mixed || $0.mode == .survival }
    }
}
