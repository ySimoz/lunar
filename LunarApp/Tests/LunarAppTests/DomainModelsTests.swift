import Foundation
import Testing
@testable import LunarApp

@Suite("Domain Models & Core JSON Compatibility")
struct DomainModelsTests {
    @Test("Deck decodes Go JSON payload and round-trips cleanly")
    func deckCodableRoundTrip() throws {
        let goJSON = """
        {
          "id": "deck-real-analysis",
          "userId": "default",
          "title": "Real Analysis & Calculus",
          "description": "Epsilon-Delta proofs and sequences.",
          "category": "Real Analysis",
          "difficulty": "hard",
          "color": "indigo",
          "cardCount": 12,
          "dueCount": 4,
          "chapters": ["Sequences & Series", "Limits & Continuity"],
          "createdAt": "2026-11-01T10:00:00Z",
          "updatedAt": "2026-11-10T12:00:00Z"
        }
        """.data(using: .utf8)!

        let deck = try JSONDecoder().decode(Deck.self, from: goJSON)
        #expect(deck.id == "deck-real-analysis")
        #expect(deck.category == .realAnalysis)
        #expect(deck.difficulty == .hard)
        #expect(deck.cardCount == 12)
        #expect(deck.dueCount == 4)
        #expect(deck.chapters == ["Sequences & Series", "Limits & Continuity"])

        let encoded = try JSONEncoder().encode(deck)
        let decodedAgain = try JSONDecoder().decode(Deck.self, from: encoded)
        #expect(decodedAgain == deck)
    }

    @Test("Flashcard decodes Go JSON with omitted omitempty fields and round-trips")
    func flashcardOmitemptyAndRoundTrip() throws {
        let minimalGoJSON = """
        {
          "id": "card-1",
          "deckId": "deck-1",
          "userId": "default",
          "order": 0,
          "front": "Define compactness.",
          "back": "Every open cover has a finite subcover.",
          "layers": [],
          "difficulty": "medium",
          "tags": [],
          "repetition": 0,
          "intervalDays": 1,
          "easeFactor": 2.5,
          "nextReviewDate": "2026-11-17T04:00:00Z",
          "totalReviews": 0,
          "correctCount": 0,
          "incorrectCount": 0,
          "history": [],
          "createdAt": "2026-11-01T10:00:00Z",
          "updatedAt": "2026-11-01T10:00:00Z"
        }
        """.data(using: .utf8)!

        let card = try JSONDecoder().decode(Flashcard.self, from: minimalGoJSON)
        #expect(card.topic == "")
        #expect(card.cardType == nil)
        #expect(card.explanation == "")
        #expect(card.lastReviewed == "")
        #expect(card.masteryStage == .new)

        let fullGoJSON = """
        {
          "id": "card-2",
          "deckId": "deck-1",
          "userId": "default",
          "topic": "Compactness",
          "order": 1,
          "cardType": "theorem",
          "front": "Heine-Borel",
          "back": "Closed and bounded in R^n.",
          "layers": [{"id": "l1", "title": "Hint", "content": "Think closed + bounded."}],
          "explanation": "Fails in infinite dimensions.",
          "difficulty": "hard",
          "tags": ["topology", "R^n"],
          "repetition": 3,
          "intervalDays": 24,
          "easeFactor": 2.6,
          "nextReviewDate": "2099-01-01T04:00:00Z",
          "lastReviewed": "2026-11-10T10:00:00Z",
          "totalReviews": 5,
          "correctCount": 5,
          "incorrectCount": 0,
          "history": [{"timestamp": "2026-11-10T10:00:00Z", "rating": 3, "intervalDays": 24, "durationMs": 4200}],
          "createdAt": "2026-11-01T10:00:00Z",
          "updatedAt": "2026-11-10T10:00:00Z"
        }
        """.data(using: .utf8)!

        let fullCard = try JSONDecoder().decode(Flashcard.self, from: fullGoJSON)
        #expect(fullCard.cardType == .theorem)
        #expect(fullCard.masteryStage == .mastered)
        #expect(fullCard.accuracyPercent == 100)
        #expect(fullCard.history.first?.durationMs == 4200)
        #expect(!fullCard.isDue())

        let reencoded = try JSONEncoder().encode(fullCard)
        let roundTripped = try JSONDecoder().decode(Flashcard.self, from: reencoded)
        #expect(roundTripped == fullCard)
    }

    @Test("ActiveSessionState, StudySessionRecord, UserPreferences, and IntervalPrediction round-trip")
    func sessionAndPreferencesCodable() throws {
        let active = ActiveSessionState(
            sessionId: "sess-1",
            deckId: "deck-1",
            deckIds: [],
            mode: .survival,
            currentIndex: 2,
            cardIds: ["c1", "c2", "c3"],
            reviewedCardIds: ["c1", "c2"],
            correctCount: 2,
            incorrectCount: 0,
            livesLeft: 3,
            startedAt: "2026-11-17T09:00:00Z"
        )
        let activeData = try JSONEncoder().encode(active)
        let activeJSON = String(data: activeData, encoding: .utf8)!
        #expect(activeJSON.contains("\"deckIds\":[]"))
        #expect(try JSONDecoder().decode(ActiveSessionState.self, from: activeData) == active)

        let sessionRec = StudySessionRecord(
            id: "sr-1",
            userId: "default",
            mode: .standard,
            deckIds: ["deck-1"],
            deckTitles: ["Topology"],
            cardsReviewed: 10,
            correctCount: 8,
            incorrectCount: 2,
            livesLeft: nil,
            durationSeconds: 185,
            completedAt: "2026-11-17T09:30:00Z"
        )
        let sessionData = try JSONEncoder().encode(sessionRec)
        #expect(try JSONDecoder().decode(StudySessionRecord.self, from: sessionData) == sessionRec)

        let prefs = UserPreferences()
        let prefsData = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(UserPreferences.self, from: prefsData) == prefs)

        let predJSON = #"{"days": 6, "label": "6d"}"#.data(using: .utf8)!
        let pred = try JSONDecoder().decode(IntervalPrediction.self, from: predJSON)
        #expect(pred == IntervalPrediction(days: 6, label: "6d"))
    }

    @Test("CoreProcessManager parses LUNAR_CORE_ADDR stdout lines")
    func parseCoreAddress() {
        #expect(
            CoreProcessManager.parseCoreAddress(fromLine: "LUNAR_CORE_ADDR=127.0.0.1:54321\n")
                == URL(string: "http://127.0.0.1:54321")
        )
        #expect(
            CoreProcessManager.parseCoreAddress(fromLine: "  LUNAR_CORE_ADDR=http://127.0.0.1:8080  ")
                == URL(string: "http://127.0.0.1:8080")
        )
        #expect(CoreProcessManager.parseCoreAddress(fromLine: "starting server...") == nil)
        #expect(CoreProcessManager.parseCoreAddress(fromLine: "LUNAR_CORE_ADDR=") == nil)
    }

    @Test("LunarFolioMark generates non-empty geometry path")
    func folioMarkPath() {
        let path = LunarFolioMark().path(in: CGRect(x: 0, y: 0, width: 32, height: 32))
        #expect(!path.isEmpty)
    }

    @Test("CoreProcessManager deduplicates concurrent starts and parses stdout immediately")
    @MainActor
    func concurrentStartDeduplication() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lunar-proc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptURL = tempDir.appendingPathComponent("mock-core.sh")
        let script = """
        #!/bin/sh
        echo "LUNAR_CORE_ADDR=127.0.0.1:49999"
        sleep 10
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let manager = CoreProcessManager(binaryURL: scriptURL)
        async let first = manager.start()
        async let second = manager.start()
        let (c1, c2) = try await (first, second)

        let url1 = await c1.baseURL
        let url2 = await c2.baseURL
        #expect(url1 == URL(string: "http://127.0.0.1:49999"))
        #expect(url2 == url1)
        #expect(manager.state == .connected(URL(string: "http://127.0.0.1:49999")!))
        await manager.stop()
        #expect(manager.state == .idle)
    }
}
