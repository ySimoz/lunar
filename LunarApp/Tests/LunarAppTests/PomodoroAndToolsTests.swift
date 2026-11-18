import AppKit
import Foundation
import Testing
@testable import LunarApp

private final class MutableClock: @unchecked Sendable {
    var now: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = start
    }
}

private final class PomodoroSpyAudio: AudioCuePlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var played: [AudioCue] = []

    func play(_ cue: AudioCue, enabled: Bool) {
        guard enabled else { return }
        lock.lock()
        played.append(cue)
        lock.unlock()
    }

    var cues: [AudioCue] {
        lock.lock()
        defer { lock.unlock() }
        return played
    }
}

private actor SettingsMockClient: CoreClientProtocol {
    var updatedPreferences: [UserPreferences] = []

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
        Flashcard(deckId: "d1", front: "F", back: "B")
    }
    func predictCard(id: String) async throws -> [String: IntervalPrediction] { [:] }
    func listSessions() async throws -> [StudySessionRecord] { [] }
    func createSession(_ session: StudySessionRecord) async throws -> StudySessionRecord { session }
    func getActiveSession() async throws -> ActiveSessionState? { nil }
    func saveActiveSession(_ state: ActiveSessionState) async throws -> ActiveSessionState { state }
    func clearActiveSession() async throws {}
    func getPreferences() async throws -> UserPreferences { UserPreferences() }

    func updatePreferences(_ preferences: UserPreferences) async throws -> UserPreferences {
        updatedPreferences.append(preferences)
        return preferences
    }

    func exportDeck(deckId: String, format: IOFormat) async throws -> ExportResult {
        ExportResult(filename: "d.json", content: "{}", mimeType: "application/json")
    }

    func importCards(_ request: ImportRequest) async throws -> ImportResult {
        ImportResult(deck: Deck(title: "D"), importedCount: 0, cards: [])
    }

    func importAPKG(
        _ data: Data,
        deckId: String?,
        deckName: String?,
        skipDuplicates: Bool
    ) async throws -> ImportResult {
        ImportResult(deck: Deck(title: deckName ?? "D"), importedCount: 0, cards: [])
    }

    func backupDatabase() async throws -> Data { Data() }
    func restoreDatabase(_ data: Data) async throws -> RestoreResult { RestoreResult(decks: 0, cards: 0) }

    func getStats(days: Int) async throws -> StatsSummary { StatsSummary() }

    @discardableResult
    func transferCards(cardIds: [String], targetDeckId: String, targetTopic: String?, targetIndex: Int?) async throws -> Int {
        cardIds.count
    }
}

@Suite("Pomodoro, 2D Grapher Math & Settings")
@MainActor
struct PomodoroAndToolsTests {
    @Test("PomodoroViewModel wall-clock reconciliation, 4-session long break cycle, skip, and reset")
    func pomodoroCycleAndReconciliation() {
        let clock = MutableClock()
        let audio = PomodoroSpyAudio()
        let vm = PomodoroViewModel(
            soundEnabled: true,
            nowProvider: { clock.now },
            audioPlayer: audio
        )
        vm.focusMinutes = 1
        vm.shortBreakMinutes = 1
        vm.longBreakMinutes = 2
        vm.autoStartBreaks = false

        #expect(vm.formattedTime == "01:00")
        vm.start()
        #expect(vm.isRunning)
        #expect(vm.progressFraction == 0.0)

        // Advance 25 seconds -> remaining 35s
        clock.now = clock.now.addingTimeInterval(25)
        vm.reconcile()
        #expect(vm.remainingSeconds == 35)
        #expect(vm.formattedTime == "00:35")

        // Advance past end -> completes focus #1 -> enters shortBreak paused
        clock.now = clock.now.addingTimeInterval(40)
        vm.reconcile()
        #expect(vm.completedSessions == 1)
        #expect(vm.mode == .shortBreak)
        #expect(!vm.isRunning)
        #expect(audio.cues.contains(.chime))

        // Skip returns to focus; reset restores full duration
        vm.skip()
        #expect(vm.mode == .focus)
        #expect(vm.remainingSeconds == 60)

        // Complete 3 more focus sessions with autoStartBreaks = true -> 4th triggers longBreak
        vm.autoStartBreaks = true
        for _ in 0..<3 {
            vm.switchMode(.focus)
            vm.start()
            clock.now = clock.now.addingTimeInterval(61)
            vm.reconcile()
        }
        #expect(vm.completedSessions == 4)
        #expect(vm.mode == .longBreak)
        #expect(vm.isRunning)
        #expect(vm.remainingSeconds == 120)

        vm.reset()
        #expect(!vm.isRunning)
        #expect(vm.remainingSeconds == 120)
    }

    @Test("MathExpressionEvaluator parses arithmetic, implicit multiplication, functions, and errors")
    func mathExpressionEvaluatorParsing() throws {
        let poly = try MathExpressionEvaluator.parseExpression("2x^2 - 3x + 1")
        #expect(poly.evaluate(x: 4, y: 0) == 21)

        let negativePower = try MathExpressionEvaluator.parseExpression("-x^2")
        #expect(negativePower.evaluate(x: 3, y: 0) == -9)

        let rightAssocPower = try MathExpressionEvaluator.parseExpression("2^3^2")
        #expect(rightAssocPower.evaluate(x: 0, y: 0) == 512)

        let trig = try MathExpressionEvaluator.parseExpression("2sin(pi / 2) + ln(e)")
        #expect(abs(trig.evaluate(x: 0, y: 0) - 3.0) < 1e-9)

        let implicitMul = try MathExpressionEvaluator.parseExpression("3(x + 1)(x - 1)")
        #expect(implicitMul.evaluate(x: 2, y: 0) == 9)

        #expect(throws: MathParseError.emptyExpression) {
            _ = try MathExpressionEvaluator.parseExpression("   ")
        }
        #expect(throws: MathParseError.multipleEqualsSigns) {
            _ = try MathExpressionEvaluator.compileEquation("y = x = 1")
        }
        #expect(throws: MathParseError.missingClosingParenthesis) {
            _ = try MathExpressionEvaluator.parseExpression("sin(x")
        }
    }

    @Test("MarchingSquares extracts circular contour for x^2 + y^2 = 4")
    func marchingSquaresCircleContour() throws {
        let ast = try MathExpressionEvaluator.compileEquation("x^2 + y^2 = 4")
        let segments = MarchingSquares.extractSegments(
            ast: ast,
            xRange: -4...4,
            yRange: -4...4,
            columns: 130,
            rows: 90
        )

        #expect(!segments.isEmpty)
        for seg in segments {
            let r1 = hypot(seg.x1, seg.y1)
            let r2 = hypot(seg.x2, seg.y2)
            #expect(abs(r1 - 2.0) < 0.15)
            #expect(abs(r2 - 2.0) < 0.15)
        }
    }

    @Test("SettingsViewModel resolves system/light/dark appearances and persists preferences")
    func settingsViewModelUpdatesAndAppearance() async {
        #expect(SettingsViewModel.resolvedAppearance(for: "") == nil)
        #expect(SettingsViewModel.resolvedAppearance(for: nil) == nil)
        #expect(SettingsViewModel.resolvedAppearance(for: "light")?.name == .aqua)
        #expect(SettingsViewModel.resolvedAppearance(for: "dark")?.name == .darkAqua)

        let mock = SettingsMockClient()
        let vm = SettingsViewModel(preferences: UserPreferences(), client: mock)
        await vm.update { prefs in
            prefs.fontFamily = "mono"
            prefs.fontSize = "lg"
            prefs.autoRevealSteps = true
            prefs.defaultLives = 5
            prefs.colorMode = "light"
        }

        let recorded = await mock.updatedPreferences
        #expect(recorded.count == 1)
        #expect(recorded[0].fontFamily == "mono")
        #expect(recorded[0].fontSize == "lg")
        #expect(recorded[0].autoRevealSteps == true)
        #expect(recorded[0].defaultLives == 5)
        #expect(recorded[0].colorMode == "light")
    }

    @Test("GrapherViewModel starts empty for a new session and retains equations, CAS history, and viewport")
    func grapherSessionStateStartsEmptyAndPersistsInSession() {
        let vm = GrapherViewModel()
        #expect(vm.activeToolTab == .focusTimer)
        #expect(vm.equations.isEmpty)
        #expect(vm.casHistory.isEmpty)
        #expect(vm.casInput.isEmpty)

        vm.activeToolTab = .grapher
        vm.addEmptyEquation()
        #expect(vm.equations.count == 1)
        #expect(vm.equations[0].expression.isEmpty)

        vm.equations[0].expression = "y = x^2"
        vm.centerX = 2.5
        vm.halfWidth = 12.0
        vm.casInput = "diff(x^3, x)"
        vm.submitCAS()

        #expect(vm.casInput.isEmpty)
        #expect(vm.casHistory.count == 1)
        #expect(vm.equations.first?.expression == "y = x^2")
        #expect(vm.centerX == 2.5)
        #expect(vm.halfWidth == 12.0)

        vm.resetViewport()
        #expect(vm.centerX == 0)
        #expect(vm.centerY == 0)
        #expect(vm.halfWidth == 8.0)

        // Anchored scroll-wheel zoom preserves cursor world point and clamps bounds
        vm.zoom(scaleFactor: 0.5, anchorNormalizedX: 0.75, anchorNormalizedY: 0.25, aspect: 0.5)
        #expect(vm.halfWidth == 4.0)
        #expect(abs(vm.centerX - 2.0) < 1e-9)
        #expect(abs(vm.centerY - 1.0) < 1e-9)

        #expect(GrapherViewModel.formatAxisValue(-1e-12, step: 1.0) == "0")
        #expect(GrapherViewModel.formatAxisValue(2.0, step: 2.0) == "2")
        #expect(GrapherViewModel.formatAxisValue(-0.5, step: 0.5) == "-0.5")
    }
}
