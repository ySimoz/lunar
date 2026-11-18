import Foundation
import UniformTypeIdentifiers

/// Complexity tier of a deck or flashcard, matching Go `domain.Difficulty`.
public enum Difficulty: String, Codable, CaseIterable, Sendable, Identifiable {
    case easy
    case medium
    case hard
    case master

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .easy: "Easy"
        case .medium: "Medium"
        case .hard: "Hard"
        case .master: "Master"
        }
    }
}

/// Pedagogical role of a mathematical flashcard, matching Go `domain.CardType`.
public enum CardType: String, Codable, CaseIterable, Sendable, Identifiable {
    case definition
    case theorem
    case example

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .definition: "Definition"
        case .theorem: "Theorem"
        case .example: "Example"
        }
    }
}

/// One of the 11 supported mathematics disciplines, matching Go `domain.SubjectCategory`.
public enum SubjectCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case calculus = "Calculus"
    case linearAlgebra = "Linear Algebra"
    case realAnalysis = "Real Analysis"
    case complexAnalysis = "Complex Analysis"
    case abstractAlgebra = "Abstract Algebra"
    case topology = "Topology"
    case probabilityStatistics = "Probability & Statistics"
    case discreteMath = "Discrete Math"
    case differentialEquations = "Differential Equations"
    case geometry = "Geometry"
    case generalMath = "General Math"

    public var id: String { rawValue }
}

/// Study session mode, matching Go `domain.StudyMode`.
public enum StudyMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case standard
    case mixed
    case survival

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .mixed: "Mixed"
        case .survival: "Survival"
        }
    }
}

/// Progressive-reveal hint or proof step on a card, matching Go `domain.CardLayer`.
public struct CardLayer: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var content: String

    public init(id: String = UUID().uuidString, title: String = "", content: String = "") {
        self.id = id
        self.title = title
        self.content = content
    }
}

/// Single spaced-repetition rating event, matching Go `domain.ReviewLog`.
public struct ReviewLog: Codable, Hashable, Sendable, Identifiable {
    public var timestamp: String
    public var rating: Int
    public var intervalDays: Int
    public var durationMs: Int64?

    public var id: String { "\(timestamp)-\(rating)-\(intervalDays)" }

    public init(timestamp: String, rating: Int, intervalDays: Int, durationMs: Int64? = nil) {
        self.timestamp = timestamp
        self.rating = rating
        self.intervalDays = intervalDays
        self.durationMs = durationMs
    }
}

/// Mathematical deck entity, matching Go `domain.Deck`.
public struct Deck: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var userId: String
    public var title: String
    public var description: String
    public var category: SubjectCategory
    public var difficulty: Difficulty
    public var color: String
    public var cardCount: Int
    public var dueCount: Int
    public var chapters: [String]
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String = "",
        userId: String = "default",
        title: String,
        description: String = "",
        category: SubjectCategory = .generalMath,
        difficulty: Difficulty = .medium,
        color: String = "emerald",
        cardCount: Int = 0,
        dueCount: Int = 0,
        chapters: [String] = [],
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.description = description
        self.category = category
        self.difficulty = difficulty
        self.color = color
        self.cardCount = cardCount
        self.dueCount = dueCount
        self.chapters = chapters
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, userId, title, description, category, difficulty, color
        case cardCount, dueCount, chapters, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        userId = try c.decodeIfPresent(String.self, forKey: .userId) ?? "default"
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        category = try c.decodeIfPresent(SubjectCategory.self, forKey: .category) ?? .generalMath
        difficulty = try c.decodeIfPresent(Difficulty.self, forKey: .difficulty) ?? .medium
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "indigo"
        cardCount = try c.decodeIfPresent(Int.self, forKey: .cardCount) ?? 0
        dueCount = try c.decodeIfPresent(Int.self, forKey: .dueCount) ?? 0
        chapters = try c.decodeIfPresent([String].self, forKey: .chapters) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

/// Learning stage classification matching Go `srs.GetCardMasteryStatus`.
public enum CardMasteryStage: String, Sendable, CaseIterable {
    case new
    case learning
    case reviewing
    case mastered

    public var label: String {
        switch self {
        case .new: "New"
        case .learning: "Learning"
        case .reviewing: "Reviewing"
        case .mastered: "Mastered"
        }
    }
}

/// Multi-layer mathematical flashcard and SM-2 state, matching Go `domain.Flashcard`.
public struct Flashcard: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var deckId: String
    public var userId: String
    public var topic: String
    public var order: Int
    public var cardType: CardType?
    public var front: String
    public var back: String
    public var layers: [CardLayer]
    public var explanation: String
    public var difficulty: Difficulty
    public var tags: [String]
    public var repetition: Int
    public var intervalDays: Int
    public var easeFactor: Double
    public var nextReviewDate: String
    public var lastReviewed: String
    public var totalReviews: Int
    public var correctCount: Int
    public var incorrectCount: Int
    public var history: [ReviewLog]
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String = "",
        deckId: String,
        userId: String = "default",
        topic: String = "",
        order: Int = 0,
        cardType: CardType? = nil,
        front: String,
        back: String,
        layers: [CardLayer] = [],
        explanation: String = "",
        difficulty: Difficulty = .medium,
        tags: [String] = [],
        repetition: Int = 0,
        intervalDays: Int = 1,
        easeFactor: Double = 2.5,
        nextReviewDate: String = "",
        lastReviewed: String = "",
        totalReviews: Int = 0,
        correctCount: Int = 0,
        incorrectCount: Int = 0,
        history: [ReviewLog] = [],
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.deckId = deckId
        self.userId = userId
        self.topic = topic
        self.order = order
        self.cardType = cardType
        self.front = front
        self.back = back
        self.layers = layers
        self.explanation = explanation
        self.difficulty = difficulty
        self.tags = tags
        self.repetition = repetition
        self.intervalDays = intervalDays
        self.easeFactor = easeFactor
        self.nextReviewDate = nextReviewDate
        self.lastReviewed = lastReviewed
        self.totalReviews = totalReviews
        self.correctCount = correctCount
        self.incorrectCount = incorrectCount
        self.history = history
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, deckId, userId, topic, order, cardType, front, back
        case layers, explanation, difficulty, tags
        case repetition, intervalDays, easeFactor, nextReviewDate, lastReviewed
        case totalReviews, correctCount, incorrectCount, history
        case createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        deckId = try c.decode(String.self, forKey: .deckId)
        userId = try c.decodeIfPresent(String.self, forKey: .userId) ?? "default"
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        if let rawType = try c.decodeIfPresent(String.self, forKey: .cardType), !rawType.isEmpty {
            cardType = CardType(rawValue: rawType)
        } else {
            cardType = nil
        }
        front = try c.decode(String.self, forKey: .front)
        back = try c.decode(String.self, forKey: .back)
        layers = try c.decodeIfPresent([CardLayer].self, forKey: .layers) ?? []
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation) ?? ""
        difficulty = try c.decodeIfPresent(Difficulty.self, forKey: .difficulty) ?? .medium
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        repetition = try c.decodeIfPresent(Int.self, forKey: .repetition) ?? 0
        intervalDays = try c.decodeIfPresent(Int.self, forKey: .intervalDays) ?? 1
        easeFactor = try c.decodeIfPresent(Double.self, forKey: .easeFactor) ?? 2.5
        nextReviewDate = try c.decodeIfPresent(String.self, forKey: .nextReviewDate) ?? ""
        lastReviewed = try c.decodeIfPresent(String.self, forKey: .lastReviewed) ?? ""
        totalReviews = try c.decodeIfPresent(Int.self, forKey: .totalReviews) ?? 0
        correctCount = try c.decodeIfPresent(Int.self, forKey: .correctCount) ?? 0
        incorrectCount = try c.decodeIfPresent(Int.self, forKey: .incorrectCount) ?? 0
        history = try c.decodeIfPresent([ReviewLog].self, forKey: .history) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(deckId, forKey: .deckId)
        try c.encode(userId, forKey: .userId)
        if !topic.isEmpty {
            try c.encode(topic, forKey: .topic)
        }
        try c.encode(order, forKey: .order)
        if let cardType {
            try c.encode(cardType, forKey: .cardType)
        }
        try c.encode(front, forKey: .front)
        try c.encode(back, forKey: .back)
        try c.encode(layers, forKey: .layers)
        if !explanation.isEmpty {
            try c.encode(explanation, forKey: .explanation)
        }
        try c.encode(difficulty, forKey: .difficulty)
        try c.encode(tags, forKey: .tags)
        try c.encode(repetition, forKey: .repetition)
        try c.encode(intervalDays, forKey: .intervalDays)
        try c.encode(easeFactor, forKey: .easeFactor)
        try c.encode(nextReviewDate, forKey: .nextReviewDate)
        if !lastReviewed.isEmpty {
            try c.encode(lastReviewed, forKey: .lastReviewed)
        }
        try c.encode(totalReviews, forKey: .totalReviews)
        try c.encode(correctCount, forKey: .correctCount)
        try c.encode(incorrectCount, forKey: .incorrectCount)
        try c.encode(history, forKey: .history)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// Mirrors Go `srs.IsCardDue`.
    public func isDue(relativeTo now: Date = Date()) -> Bool {
        if nextReviewDate.isEmpty || totalReviews == 0 {
            return true
        }
        guard let dueAt = ISO8601DateFormatter.lunarParse(nextReviewDate) else {
            return true
        }
        return dueAt <= now
    }

    /// Mirrors Go `srs.GetCardMasteryStatus`.
    public var masteryStage: CardMasteryStage {
        if totalReviews == 0 {
            return .new
        }
        if repetition < 2 {
            return .learning
        }
        let accuracy = Double(correctCount) / Double(max(1, totalReviews))
        if intervalDays >= 21 && accuracy >= 0.8 {
            return .mastered
        }
        return .reviewing
    }

    /// Accuracy percentage (0...100), nil when unreviewed.
    public var accuracyPercent: Int? {
        guard totalReviews > 0 else { return nil }
        return Int((Double(correctCount) / Double(totalReviews) * 100.0).rounded())
    }

    /// Formats `intervalDays` matching Go `srs.FormatIntervalDays`.
    public var formattedInterval: String {
        Self.formatIntervalDays(intervalDays)
    }

    public static func formatIntervalDays(_ days: Int) -> String {
        if days <= 0 { return "< 1d" }
        if days == 1 { return "1d" }
        if days < 30 { return "\(days)d" }
        if days < 365 {
            return formatScaled(Double(days) / 30.0, unit: "mo")
        }
        return formatScaled(Double(days) / 365.0, unit: "y")
    }

    private static func formatScaled(_ value: Double, unit: String) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))\(unit)"
        }
        return String(format: "%.1f%@", rounded, unit)
    }
}

/// Completed study or gauntlet run, matching Go `domain.StudySessionRecord`.
public struct StudySessionRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var userId: String
    public var mode: StudyMode
    public var deckIds: [String]
    public var deckTitles: [String]
    public var cardsReviewed: Int
    public var correctCount: Int
    public var incorrectCount: Int
    public var livesLeft: Int?
    public var durationSeconds: Int
    public var completedAt: String

    public init(
        id: String = "",
        userId: String = "default",
        mode: StudyMode,
        deckIds: [String] = [],
        deckTitles: [String] = [],
        cardsReviewed: Int = 0,
        correctCount: Int = 0,
        incorrectCount: Int = 0,
        livesLeft: Int? = nil,
        durationSeconds: Int = 0,
        completedAt: String = ""
    ) {
        self.id = id
        self.userId = userId
        self.mode = mode
        self.deckIds = deckIds
        self.deckTitles = deckTitles
        self.cardsReviewed = cardsReviewed
        self.correctCount = correctCount
        self.incorrectCount = incorrectCount
        self.livesLeft = livesLeft
        self.durationSeconds = durationSeconds
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, userId, mode, deckIds, deckTitles, cardsReviewed
        case correctCount, incorrectCount, livesLeft, durationSeconds, completedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        userId = try c.decodeIfPresent(String.self, forKey: .userId) ?? "default"
        mode = try c.decode(StudyMode.self, forKey: .mode)
        deckIds = try c.decodeIfPresent([String].self, forKey: .deckIds) ?? []
        deckTitles = try c.decodeIfPresent([String].self, forKey: .deckTitles) ?? []
        cardsReviewed = try c.decodeIfPresent(Int.self, forKey: .cardsReviewed) ?? 0
        correctCount = try c.decodeIfPresent(Int.self, forKey: .correctCount) ?? 0
        incorrectCount = try c.decodeIfPresent(Int.self, forKey: .incorrectCount) ?? 0
        livesLeft = try c.decodeIfPresent(Int.self, forKey: .livesLeft)
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt) ?? ""
    }
}

/// Crash-recovery snapshot of an active study session, matching Go `domain.ActiveSessionState`.
public struct ActiveSessionState: Codable, Hashable, Sendable {
    public var sessionId: String
    public var deckId: String?
    public var deckIds: [String]
    public var mode: StudyMode
    public var currentIndex: Int
    public var cardIds: [String]
    public var reviewedCardIds: [String]
    public var correctCount: Int
    public var incorrectCount: Int
    public var livesLeft: Int?
    public var startedAt: String

    public init(
        sessionId: String,
        deckId: String? = nil,
        deckIds: [String] = [],
        mode: StudyMode,
        currentIndex: Int = 0,
        cardIds: [String] = [],
        reviewedCardIds: [String] = [],
        correctCount: Int = 0,
        incorrectCount: Int = 0,
        livesLeft: Int? = nil,
        startedAt: String = ""
    ) {
        self.sessionId = sessionId
        self.deckId = deckId
        self.deckIds = deckIds
        self.mode = mode
        self.currentIndex = currentIndex
        self.cardIds = cardIds
        self.reviewedCardIds = reviewedCardIds
        self.correctCount = correctCount
        self.incorrectCount = incorrectCount
        self.livesLeft = livesLeft
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionId, deckId, deckIds, mode, currentIndex
        case cardIds, reviewedCardIds, correctCount, incorrectCount, livesLeft, startedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        deckId = try c.decodeIfPresent(String.self, forKey: .deckId)
        deckIds = try c.decodeIfPresent([String].self, forKey: .deckIds) ?? []
        mode = try c.decode(StudyMode.self, forKey: .mode)
        currentIndex = try c.decodeIfPresent(Int.self, forKey: .currentIndex) ?? 0
        cardIds = try c.decodeIfPresent([String].self, forKey: .cardIds) ?? []
        reviewedCardIds = try c.decodeIfPresent([String].self, forKey: .reviewedCardIds) ?? []
        correctCount = try c.decodeIfPresent(Int.self, forKey: .correctCount) ?? 0
        incorrectCount = try c.decodeIfPresent(Int.self, forKey: .incorrectCount) ?? 0
        livesLeft = try c.decodeIfPresent(Int.self, forKey: .livesLeft)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
    }
}

/// Persisted display, audio, and study behavior settings, matching Go `domain.UserPreferences`.
public struct UserPreferences: Codable, Hashable, Sendable {
    public var fontFamily: String
    public var fontSize: String
    public var retroUIFont: String?
    public var theme: String
    public var colorMode: String?
    public var soundEnabled: Bool
    public var defaultLives: Int
    public var autoRevealSteps: Bool
    public var showHelperDescriptions: Bool
    public var clockStyle: String?

    public init(
        fontFamily: String = "serif",
        fontSize: String = "base",
        retroUIFont: String? = "share-tech",
        theme: String = "lunar-emerald",
        colorMode: String? = "dark",
        soundEnabled: Bool = true,
        defaultLives: Int = 3,
        autoRevealSteps: Bool = false,
        showHelperDescriptions: Bool = false,
        clockStyle: String? = "circular"
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.retroUIFont = retroUIFont
        self.theme = theme
        self.colorMode = colorMode
        self.soundEnabled = soundEnabled
        self.defaultLives = defaultLives
        self.autoRevealSteps = autoRevealSteps
        self.showHelperDescriptions = showHelperDescriptions
        self.clockStyle = clockStyle
    }
}

/// Projected next interval for a rating button, matching Go `srs.IntervalPrediction`.
public struct IntervalPrediction: Codable, Hashable, Sendable {
    public var days: Int
    public var label: String

    public init(days: Int, label: String) {
        self.days = days
        self.label = label
    }
}

// MARK: - Import / Export Models

/// Supported deck export/import formats, matching Go `internal/io.Format`.
public enum IOFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case markdown = "md"
    case anki = "anki"
    case csv = "csv"
    case json = "json"
    case apkg = "apkg"

    public static let exportCases: [IOFormat] = [.markdown, .anki, .csv, .json]
    public static let importCases: [IOFormat] = [.markdown, .anki, .csv, .json, .apkg]

    public var id: String { rawValue }

    public var supportsExport: Bool {
        self != .apkg
    }

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .anki: "Anki TSV"
        case .csv: "CSV"
        case .json: "JSON"
        case .apkg: "Anki (.apkg)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .anki: "txt"
        case .csv: "csv"
        case .json: "json"
        case .apkg: "apkg"
        }
    }

    public var contentType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .anki: .tabSeparatedText
        case .csv: .commaSeparatedText
        case .json: .json
        case .apkg: UTType(filenameExtension: "apkg") ?? .data
        }
    }

    public static func detect(from url: URL) -> IOFormat? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return .markdown
        case "csv": return .csv
        case "tsv", "txt": return .anki
        case "json": return .json
        case "apkg": return .apkg
        default: return nil
        }
    }
}

/// Library counts returned by `POST /api/restore`, matching Go `store.RestoreCounts`.
public struct RestoreResult: Codable, Hashable, Sendable {
    public var decks: Int
    public var cards: Int

    public init(decks: Int, cards: Int) {
        self.decks = decks
        self.cards = cards
    }
}

/// Export payload returned by `GET /api/decks/{id}/export`.
public struct ExportResult: Codable, Hashable, Sendable {
    public var filename: String
    public var content: String
    public var mimeType: String

    public init(filename: String, content: String, mimeType: String) {
        self.filename = filename
        self.content = content
        self.mimeType = mimeType
    }
}

/// Import request payload sent to `POST /api/import`.
public struct ImportRequest: Codable, Hashable, Sendable {
    public var format: String
    public var content: String
    public var targetDeckId: String?
    public var newDeckTitle: String?
    public var category: SubjectCategory?
    public var targetTopic: String?

    public init(
        format: IOFormat,
        content: String,
        targetDeckId: String? = nil,
        newDeckTitle: String? = nil,
        category: SubjectCategory? = nil,
        targetTopic: String? = nil
    ) {
        self.format = format.rawValue
        self.content = content
        self.targetDeckId = targetDeckId
        self.newDeckTitle = newDeckTitle
        self.category = category
        self.targetTopic = targetTopic
    }
}

/// Import response payload returned by `POST /api/import`.
public struct ImportResult: Codable, Hashable, Sendable {
    public var deck: Deck
    public var importedCount: Int
    public var cards: [Flashcard]

    public init(deck: Deck, importedCount: Int, cards: [Flashcard]) {
        self.deck = deck
        self.importedCount = importedCount
        self.cards = cards
    }
}

/// Request payload for `POST /api/cards/transfer`, matching Go `domain.TransferCardsRequest`.
public struct TransferCardsRequest: Codable, Hashable, Sendable {
    public var cardIds: [String]
    public var targetDeckId: String
    public var targetTopic: String?
    public var targetIndex: Int?

    public init(
        cardIds: [String],
        targetDeckId: String,
        targetTopic: String? = nil,
        targetIndex: Int? = nil
    ) {
        self.cardIds = cardIds
        self.targetDeckId = targetDeckId
        self.targetTopic = targetTopic
        self.targetIndex = targetIndex
    }
}

// MARK: - Analytics & Streaks Models

/// Learning-stage distribution matching Go `stats.MasteryPipeline`.
public struct MasteryPipeline: Codable, Hashable, Sendable {
    public var newCount: Int
    public var learningCount: Int
    public var reviewCount: Int
    public var masteredCount: Int
    public var masteredPercent: Int

    public init(
        newCount: Int = 0,
        learningCount: Int = 0,
        reviewCount: Int = 0,
        masteredCount: Int = 0,
        masteredPercent: Int = 0
    ) {
        self.newCount = newCount
        self.learningCount = learningCount
        self.reviewCount = reviewCount
        self.masteredCount = masteredCount
        self.masteredPercent = masteredPercent
    }
}

/// Per-deck mastery & ease metrics matching Go `stats.DeckBreakdown`.
public struct DeckBreakdown: Codable, Hashable, Sendable, Identifiable {
    public var deckId: String
    public var title: String
    public var totalCards: Int
    public var dueCards: Int
    public var masteredCards: Int
    public var masteredPercent: Int
    public var averageEase: Double

    public var id: String { deckId }

    public init(
        deckId: String,
        title: String,
        totalCards: Int = 0,
        dueCards: Int = 0,
        masteredCards: Int = 0,
        masteredPercent: Int = 0,
        averageEase: Double = 2.5
    ) {
        self.deckId = deckId
        self.title = title
        self.totalCards = totalCards
        self.dueCards = dueCards
        self.masteredCards = masteredCards
        self.masteredPercent = masteredPercent
        self.averageEase = averageEase
    }
}

/// One local calendar day's review and study-time totals, matching Go `stats.DailyActivity`.
public struct DailyActivity: Codable, Hashable, Sendable, Identifiable {
    public var date: String
    public var reviews: Int
    public var correct: Int
    public var studySeconds: Int

    public var id: String { date }

    public var parsedDate: Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }

    public init(date: String, reviews: Int = 0, correct: Int = 0, studySeconds: Int = 0) {
        self.date = date
        self.reviews = reviews
        self.correct = correct
        self.studySeconds = studySeconds
    }
}

/// Global KPIs, mastery pipeline, deck breakdowns, and daily activity matching Go `stats.Summary`.
public struct StatsSummary: Codable, Hashable, Sendable {
    public var totalCards: Int
    public var dueCards: Int
    public var totalReviews: Int
    public var totalCorrect: Int
    public var retentionRate: Int
    public var totalStudySeconds: Int
    public var currentStreakDays: Int
    public var longestStreakDays: Int
    public var masteryPipeline: MasteryPipeline
    public var deckBreakdown: [DeckBreakdown]
    public var dailyActivity: [DailyActivity]

    public init(
        totalCards: Int = 0,
        dueCards: Int = 0,
        totalReviews: Int = 0,
        totalCorrect: Int = 0,
        retentionRate: Int = 0,
        totalStudySeconds: Int = 0,
        currentStreakDays: Int = 0,
        longestStreakDays: Int = 0,
        masteryPipeline: MasteryPipeline = MasteryPipeline(),
        deckBreakdown: [DeckBreakdown] = [],
        dailyActivity: [DailyActivity] = []
    ) {
        self.totalCards = totalCards
        self.dueCards = dueCards
        self.totalReviews = totalReviews
        self.totalCorrect = totalCorrect
        self.retentionRate = retentionRate
        self.totalStudySeconds = totalStudySeconds
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.masteryPipeline = masteryPipeline
        self.deckBreakdown = deckBreakdown
        self.dailyActivity = dailyActivity
    }
}

extension ISO8601DateFormatter {
    static func lunarParse(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) {
            return d
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }

    static func lunarShortDate(_ raw: String) -> String {
        guard !raw.isEmpty, let date = lunarParse(raw) else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
