import Foundation
import Testing
@testable import LunarApp

private actor MockIOClient: CoreClientProtocol {
    var exportedRequests: [(deckId: String, format: IOFormat)] = []
    var importedRequests: [ImportRequest] = []
    var stubExport: ExportResult
    var stubImport: ImportResult

    init(stubExport: ExportResult, stubImport: ImportResult) {
        self.stubExport = stubExport
        self.stubImport = stubImport
    }

    func health() async throws -> Bool { true }
    func listDecks() async throws -> [Deck] { [stubImport.deck] }
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
        Flashcard(deckId: "d1", front: "F", back: "B")
    }
    func predictCard(id: String) async throws -> [String: IntervalPrediction] { [:] }
    func listSessions() async throws -> [StudySessionRecord] { [] }
    func createSession(_ session: StudySessionRecord) async throws -> StudySessionRecord { session }
    func getActiveSession() async throws -> ActiveSessionState? { nil }
    func saveActiveSession(_ state: ActiveSessionState) async throws -> ActiveSessionState { state }
    func clearActiveSession() async throws {}
    func getPreferences() async throws -> UserPreferences { UserPreferences() }
    func updatePreferences(_ preferences: UserPreferences) async throws -> UserPreferences { preferences }

    func exportDeck(deckId: String, format: IOFormat) async throws -> ExportResult {
        exportedRequests.append((deckId: deckId, format: format))
        return stubExport
    }

    func importCards(_ request: ImportRequest) async throws -> ImportResult {
        importedRequests.append(request)
        return stubImport
    }

    func getStats(days: Int) async throws -> StatsSummary {
        StatsSummary()
    }

    @discardableResult
    func transferCards(cardIds: [String], targetDeckId: String, targetTopic: String?, targetIndex: Int?) async throws -> Int {
        cardIds.count
    }
}

@Suite("Import / Export Models & ViewModel")
struct ImportExportTests {
    @Test("ExportResult, ImportRequest, and ImportResult match Go JSON fields")
    func importExportCodableCompatibility() throws {
        let exportJSON = """
        {
          "filename": "real_analysis.md",
          "content": "# Real Analysis\\n\\n## Card 1 (Definition): Limit\\n",
          "mimeType": "text/markdown"
        }
        """.data(using: .utf8)!

        let decodedExport = try JSONDecoder().decode(ExportResult.self, from: exportJSON)
        #expect(decodedExport.filename == "real_analysis.md")
        #expect(decodedExport.mimeType == "text/markdown")

        let req = ImportRequest(
            format: .csv,
            content: "Front,Back\nA,B",
            targetDeckId: nil,
            newDeckTitle: "Algebra",
            category: .abstractAlgebra,
            targetTopic: "Groups"
        )
        let reqData = try JSONEncoder().encode(req)
        let reqObj = try JSONSerialization.jsonObject(with: reqData) as! [String: Any]
        #expect(reqObj["format"] as? String == "csv")
        #expect(reqObj["newDeckTitle"] as? String == "Algebra")
        #expect(reqObj["category"] as? String == "Abstract Algebra")
        #expect(reqObj["targetTopic"] as? String == "Groups")

        let importResponseJSON = """
        {
          "deck": {
            "id": "deck-imported",
            "userId": "default",
            "title": "Algebra",
            "description": "",
            "category": "Abstract Algebra",
            "difficulty": "medium",
            "color": "emerald",
            "cardCount": 1,
            "dueCount": 1,
            "chapters": ["Groups"],
            "createdAt": "2026-11-17T10:00:00Z",
            "updatedAt": "2026-11-17T10:00:00Z"
          },
          "importedCount": 1,
          "cards": [
            {
              "id": "card-1",
              "deckId": "deck-imported",
              "userId": "default",
              "topic": "Groups",
              "order": 0,
              "front": "A",
              "back": "B",
              "layers": [],
              "difficulty": "medium",
              "tags": [],
              "repetition": 0,
              "intervalDays": 1,
              "easeFactor": 2.5,
              "nextReviewDate": "2026-11-17T10:00:00Z",
              "totalReviews": 0,
              "correctCount": 0,
              "incorrectCount": 0,
              "history": [],
              "createdAt": "2026-11-17T10:00:00Z",
              "updatedAt": "2026-11-17T10:00:00Z"
            }
          ]
        }
        """.data(using: .utf8)!

        let decodedImport = try JSONDecoder().decode(ImportResult.self, from: importResponseJSON)
        #expect(decodedImport.deck.id == "deck-imported")
        #expect(decodedImport.importedCount == 1)
        #expect(decodedImport.cards.count == 1)
    }

    @Test("IOFormat detects extensions cleanly")
    func ioFormatDetection() {
        #expect(IOFormat.detect(from: URL(fileURLWithPath: "/tmp/notes.md")) == .markdown)
        #expect(IOFormat.detect(from: URL(fileURLWithPath: "/tmp/cards.csv")) == .csv)
        #expect(IOFormat.detect(from: URL(fileURLWithPath: "/tmp/anki.txt")) == .anki)
        #expect(IOFormat.detect(from: URL(fileURLWithPath: "/tmp/anki.tsv")) == .anki)
        #expect(IOFormat.detect(from: URL(fileURLWithPath: "/tmp/bundle.json")) == .json)
    }

    @Test("ImportExportViewModel loads export preview and performs import")
    @MainActor
    func viewModelExportAndImportFlows() async {
        let existingDeck = Deck(id: "d1", title: "Topology", category: .topology)
        let importedDeck = Deck(id: "d2", title: "New Calculus", category: .calculus, cardCount: 2, dueCount: 2)
        let mock = MockIOClient(
            stubExport: ExportResult(filename: "topology.md", content: "# Topology", mimeType: "text/markdown"),
            stubImport: ImportResult(
                deck: importedDeck,
                importedCount: 2,
                cards: [
                    Flashcard(id: "c1", deckId: "d2", front: "F1", back: "B1"),
                    Flashcard(id: "c2", deckId: "d2", front: "F2", back: "B2")
                ]
            )
        )

        let vm = ImportExportViewModel(
            decks: [existingDeck],
            initialDeckId: "d1",
            initialTab: .export,
            client: mock
        )
        vm.exportFormat = .markdown
        await vm.loadExportPreview()

        #expect(vm.exportResult?.filename == "topology.md")
        #expect(vm.exportResult?.content == "# Topology")
        let exports = await mock.exportedRequests
        #expect(exports.count == 1)
        #expect(exports[0].deckId == "d1")
        #expect(exports[0].format == .markdown)

        // Import into new deck
        vm.activeTab = .import
        vm.importTarget = .newDeck
        vm.newDeckTitle = "New Calculus"
        vm.newDeckCategory = .calculus
        vm.importFormat = .csv
        vm.targetTopic = "Derivatives"
        vm.importContent = "Front,Back\nF1,B1\nF2,B2"
        #expect(vm.canImport)

        let result = await vm.performImport()
        #expect(result?.importedCount == 2)
        #expect(vm.lastImportResult?.deck.id == "d2")
        #expect(vm.decks.contains(where: { $0.id == "d2" }))

        let imports = await mock.importedRequests
        #expect(imports.count == 1)
        #expect(imports[0].format == "csv")
        #expect(imports[0].newDeckTitle == "New Calculus")
        #expect(imports[0].category == .calculus)
        #expect(imports[0].targetTopic == "Derivatives")
    }
}
