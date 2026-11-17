package api_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"lunar/core/internal/api"
	"lunar/core/internal/domain"
	"lunar/core/internal/srs"
	"lunar/core/internal/store"
)

func newTestServer(t *testing.T) http.Handler {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "api_test.db"))
	if err != nil {
		t.Fatalf("store.Open failed: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.SeedIfEmpty(); err != nil {
		t.Fatalf("SeedIfEmpty failed: %v", err)
	}
	return api.NewServer(s).Handler()
}

func doJSON(t *testing.T, h http.Handler, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode request body: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestHealthAndSeededDecks(t *testing.T) {
	h := newTestServer(t)

	res := doJSON(t, h, http.MethodGet, "/health", nil)
	if res.Code != http.StatusOK {
		t.Fatalf("GET /health = %d, want 200", res.Code)
	}

	decksRes := doJSON(t, h, http.MethodGet, "/api/decks", nil)
	if decksRes.Code != http.StatusOK {
		t.Fatalf("GET /api/decks = %d, want 200", decksRes.Code)
	}
	var decks []domain.Deck
	if err := json.Unmarshal(decksRes.Body.Bytes(), &decks); err != nil {
		t.Fatalf("decode decks: %v", err)
	}
	if len(decks) != 4 {
		t.Fatalf("len(decks) = %d, want 4", len(decks))
	}
}

func TestDeckAndCardCRUDReviewPredictReorder(t *testing.T) {
	h := newTestServer(t)

	// Invalid deck returns 400
	badDeck := doJSON(t, h, http.MethodPost, "/api/decks", map[string]any{"title": ""})
	if badDeck.Code != http.StatusBadRequest {
		t.Fatalf("POST invalid deck = %d, want 400", badDeck.Code)
	}

	// Create deck
	deckRes := doJSON(t, h, http.MethodPost, "/api/decks", domain.Deck{
		Title:       "Complex Analysis",
		Description: "Holomorphic functions and residues",
		Category:    domain.CategoryComplexAnalysis,
		Difficulty:  domain.DifficultyHard,
		Color:       "cyan",
	})
	if deckRes.Code != http.StatusCreated {
		t.Fatalf("POST /api/decks = %d: %s", deckRes.Code, deckRes.Body.String())
	}
	var deck domain.Deck
	_ = json.Unmarshal(deckRes.Body.Bytes(), &deck)

	// Update deck
	updDeck := doJSON(t, h, http.MethodPut, "/api/decks/"+deck.ID, domain.Deck{
		Title:      "Complex Analysis II",
		Category:   domain.CategoryComplexAnalysis,
		Difficulty: domain.DifficultyMaster,
	})
	if updDeck.Code != http.StatusOK {
		t.Fatalf("PUT /api/decks = %d: %s", updDeck.Code, updDeck.Body.String())
	}

	// Create 2 cards
	c1Res := doJSON(t, h, http.MethodPost, "/api/cards", domain.Flashcard{
		DeckID:     deck.ID,
		Front:      "State Cauchy's Integral Formula.",
		Back:       "$f(a) = \\frac{1}{2\\pi i} \\oint_\\gamma \\frac{f(z)}{z-a} dz$",
		Difficulty: domain.DifficultyMedium,
		Layers:     []domain.CardLayer{{Title: "Hint", Content: "Winding number 1"}},
	})
	if c1Res.Code != http.StatusCreated {
		t.Fatalf("POST /api/cards c1 = %d: %s", c1Res.Code, c1Res.Body.String())
	}
	var c1 domain.Flashcard
	_ = json.Unmarshal(c1Res.Body.Bytes(), &c1)

	c2Res := doJSON(t, h, http.MethodPost, "/api/cards", domain.Flashcard{
		DeckID:     deck.ID,
		Front:      "State Liouville's Theorem.",
		Back:       "Every bounded entire function is constant.",
		Difficulty: domain.DifficultyEasy,
	})
	var c2 domain.Flashcard
	_ = json.Unmarshal(c2Res.Body.Bytes(), &c2)

	// Predict before review
	predRes := doJSON(t, h, http.MethodGet, "/api/cards/"+c1.ID+"/predict", nil)
	if predRes.Code != http.StatusOK {
		t.Fatalf("GET predict = %d: %s", predRes.Code, predRes.Body.String())
	}
	var preds map[string]srs.IntervalPrediction
	if err := json.Unmarshal(predRes.Body.Bytes(), &preds); err != nil {
		t.Fatalf("decode predict: %v", err)
	}
	if preds["4"].Days != 4 || preds["1"].Label != "1d" {
		t.Fatalf("unexpected predictions: %+v", preds)
	}

	// Review c1 (rating 4 = Easy)
	dur := int64(1500)
	revRes := doJSON(t, h, http.MethodPost, "/api/cards/"+c1.ID+"/review", map[string]any{
		"rating":     4,
		"durationMs": dur,
	})
	if revRes.Code != http.StatusOK {
		t.Fatalf("POST review = %d: %s", revRes.Code, revRes.Body.String())
	}
	var reviewed domain.Flashcard
	_ = json.Unmarshal(revRes.Body.Bytes(), &reviewed)
	if reviewed.IntervalDays != 4 || reviewed.TotalReviews != 1 || len(reviewed.History) != 1 {
		t.Fatalf("unexpected reviewed card: %+v", reviewed)
	}

	// Bad review rating returns 400
	if badRev := doJSON(t, h, http.MethodPost, "/api/cards/"+c1.ID+"/review", map[string]any{"rating": 9}); badRev.Code != http.StatusBadRequest {
		t.Fatalf("POST bad review = %d, want 400", badRev.Code)
	}

	// Decoupled content update preserves SRS
	updCardRes := doJSON(t, h, http.MethodPut, "/api/cards/"+c1.ID, domain.Flashcard{
		Front:      "Updated Front",
		Back:       "Updated Back",
		Difficulty: domain.DifficultyHard,
	})
	if updCardRes.Code != http.StatusOK {
		t.Fatalf("PUT /api/cards = %d: %s", updCardRes.Code, updCardRes.Body.String())
	}
	var updCard domain.Flashcard
	_ = json.Unmarshal(updCardRes.Body.Bytes(), &updCard)
	if updCard.Front != "Updated Front" || updCard.IntervalDays != 4 || updCard.TotalReviews != 1 {
		t.Fatalf("SRS clobbered on PUT: %+v", updCard)
	}

	// Reorder
	reordRes := doJSON(t, h, http.MethodPost, "/api/decks/"+deck.ID+"/reorder", map[string]any{
		"cardIds": []string{c2.ID, c1.ID},
	})
	if reordRes.Code != http.StatusOK {
		t.Fatalf("POST reorder = %d: %s", reordRes.Code, reordRes.Body.String())
	}
	deckCardsRes := doJSON(t, h, http.MethodGet, "/api/decks/"+deck.ID+"/cards", nil)
	var deckCards []domain.Flashcard
	_ = json.Unmarshal(deckCardsRes.Body.Bytes(), &deckCards)
	if len(deckCards) != 2 || deckCards[0].ID != c2.ID {
		t.Fatalf("reordered deck cards = %+v", deckCards)
	}

	// All cards endpoint
	allCardsRes := doJSON(t, h, http.MethodGet, "/api/cards", nil)
	if allCardsRes.Code != http.StatusOK {
		t.Fatalf("GET /api/cards = %d", allCardsRes.Code)
	}

	// Delete card and deck
	if delCard := doJSON(t, h, http.MethodDelete, "/api/cards/"+c2.ID, nil); delCard.Code != http.StatusNoContent {
		t.Fatalf("DELETE card = %d, want 204", delCard.Code)
	}
	if delDeck := doJSON(t, h, http.MethodDelete, "/api/decks/"+deck.ID, nil); delDeck.Code != http.StatusNoContent {
		t.Fatalf("DELETE deck = %d, want 204", delDeck.Code)
	}
}

func TestSessionsActiveSessionAndPreferencesAPI(t *testing.T) {
	h := newTestServer(t)

	// Sessions
	sessRes := doJSON(t, h, http.MethodPost, "/api/sessions", domain.StudySessionRecord{
		Mode:            domain.StudyModeStandard,
		DeckIDs:         []string{"deck-real-analysis"},
		DeckTitles:      []string{"Real Analysis & Calculus"},
		CardsReviewed:   5,
		CorrectCount:    4,
		IncorrectCount:  1,
		DurationSeconds: 120,
	})
	if sessRes.Code != http.StatusCreated {
		t.Fatalf("POST /api/sessions = %d: %s", sessRes.Code, sessRes.Body.String())
	}
	listSess := doJSON(t, h, http.MethodGet, "/api/sessions", nil)
	if listSess.Code != http.StatusOK {
		t.Fatalf("GET /api/sessions = %d", listSess.Code)
	}

	// Active session lifecycle
	if r := doJSON(t, h, http.MethodGet, "/api/active-session", nil); r.Code != http.StatusNotFound {
		t.Fatalf("GET empty active-session = %d, want 404", r.Code)
	}
	putActive := doJSON(t, h, http.MethodPut, "/api/active-session", domain.ActiveSessionState{
		SessionID:       "s-123",
		DeckID:          "deck-real-analysis",
		Mode:            domain.StudyModeStandard,
		CurrentIndex:    2,
		CardIDs:         []string{"card-ra-1", "card-ra-2"},
		ReviewedCardIDs: []string{"card-ra-1"},
		CorrectCount:    1,
	})
	if putActive.Code != http.StatusOK {
		t.Fatalf("PUT active-session = %d: %s", putActive.Code, putActive.Body.String())
	}
	if r := doJSON(t, h, http.MethodGet, "/api/active-session", nil); r.Code != http.StatusOK {
		t.Fatalf("GET saved active-session = %d, want 200", r.Code)
	}
	if r := doJSON(t, h, http.MethodDelete, "/api/active-session", nil); r.Code != http.StatusNoContent {
		t.Fatalf("DELETE active-session = %d, want 204", r.Code)
	}
	if r := doJSON(t, h, http.MethodGet, "/api/active-session", nil); r.Code != http.StatusNotFound {
		t.Fatalf("GET cleared active-session = %d, want 404", r.Code)
	}

	// Preferences
	getPrefs := doJSON(t, h, http.MethodGet, "/api/preferences", nil)
	if getPrefs.Code != http.StatusOK {
		t.Fatalf("GET /api/preferences = %d", getPrefs.Code)
	}
	var prefs domain.UserPreferences
	_ = json.Unmarshal(getPrefs.Body.Bytes(), &prefs)
	prefs.FontFamily = "sans"
	prefs.DefaultLives = 5

	putPrefs := doJSON(t, h, http.MethodPut, "/api/preferences", prefs)
	if putPrefs.Code != http.StatusOK {
		t.Fatalf("PUT /api/preferences = %d: %s", putPrefs.Code, putPrefs.Body.String())
	}
	prefs.FontFamily = "comic"
	if badPrefs := doJSON(t, h, http.MethodPut, "/api/preferences", prefs); badPrefs.Code != http.StatusBadRequest {
		t.Fatalf("PUT invalid preferences = %d, want 400", badPrefs.Code)
	}
}

func TestAPI_ConflictsBodyLimitsTrailingJSONAndValidation(t *testing.T) {
	h := newTestServer(t)

	// 1. Unique/Primary key constraint -> 409 Conflict
	dPayload := domain.Deck{
		ID:         "dup-deck-id",
		Title:      "Unique Deck",
		Category:   domain.CategoryCalculus,
		Difficulty: domain.DifficultyEasy,
	}
	if res := doJSON(t, h, http.MethodPost, "/api/decks", dPayload); res.Code != http.StatusCreated {
		t.Fatalf("first POST deck = %d, want 201", res.Code)
	}
	if res := doJSON(t, h, http.MethodPost, "/api/decks", dPayload); res.Code != http.StatusConflict {
		t.Fatalf("duplicate POST deck = %d, want 409 (%s)", res.Code, res.Body.String())
	}

	cPayload := domain.Flashcard{
		ID:         "dup-card-id",
		DeckID:     "dup-deck-id",
		Front:      "Q",
		Back:       "A",
		Difficulty: domain.DifficultyEasy,
	}
	if res := doJSON(t, h, http.MethodPost, "/api/cards", cPayload); res.Code != http.StatusCreated {
		t.Fatalf("first POST card = %d, want 201", res.Code)
	}
	if res := doJSON(t, h, http.MethodPost, "/api/cards", cPayload); res.Code != http.StatusConflict {
		t.Fatalf("duplicate POST card = %d, want 409 (%s)", res.Code, res.Body.String())
	}

	// 2. Trailing JSON tokens rejected with 400
	req := httptest.NewRequest(http.MethodPost, "/api/decks", strings.NewReader(`{"title":"A","category":"Calculus","difficulty":"easy"} {"extra":true}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("trailing JSON token = %d, want 400 (%s)", rec.Code, rec.Body.String())
	}

	// 3. Oversized request body (> 1 MiB) rejected with 413
	huge := strings.Repeat("a", (1<<20)+1024)
	reqHuge := httptest.NewRequest(http.MethodPost, "/api/decks", strings.NewReader(`{"title":"`+huge+`"}`))
	reqHuge.Header.Set("Content-Type", "application/json")
	recHuge := httptest.NewRecorder()
	h.ServeHTTP(recHuge, reqHuge)
	if recHuge.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized body = %d, want 413 (%s)", recHuge.Code, recHuge.Body.String())
	}

	// 4. ActiveSessionState serializes empty deckIds as [] and rejects negative livesLeft
	putActive := doJSON(t, h, http.MethodPut, "/api/active-session", map[string]any{
		"sessionId": "s-empty-decks",
		"mode":      "standard",
	})
	if putActive.Code != http.StatusOK {
		t.Fatalf("PUT active-session = %d: %s", putActive.Code, putActive.Body.String())
	}
	if !strings.Contains(putActive.Body.String(), `"deckIds":[]`) {
		t.Fatalf("expected \"deckIds\":[] in response, got %s", putActive.Body.String())
	}
	if badActive := doJSON(t, h, http.MethodPut, "/api/active-session", map[string]any{
		"sessionId": "s-neg-lives",
		"mode":      "survival",
		"livesLeft": -1,
	}); badActive.Code != http.StatusBadRequest {
		t.Fatalf("PUT active-session negative livesLeft = %d, want 400", badActive.Code)
	}

	// 5. Negative durationMs and negative session livesLeft rejected with 400
	if badRev := doJSON(t, h, http.MethodPost, "/api/cards/dup-card-id/review", map[string]any{
		"rating":     3,
		"durationMs": -50,
	}); badRev.Code != http.StatusBadRequest {
		t.Fatalf("POST review negative durationMs = %d, want 400", badRev.Code)
	}
	if badSess := doJSON(t, h, http.MethodPost, "/api/sessions", map[string]any{
		"mode":      "survival",
		"livesLeft": -2,
	}); badSess.Code != http.StatusBadRequest {
		t.Fatalf("POST session negative livesLeft = %d, want 400", badSess.Code)
	}

	// 6. Reorder validation errors return 400
	if badReord := doJSON(t, h, http.MethodPost, "/api/decks/dup-deck-id/reorder", map[string]any{
		"cardIds": []string{},
	}); badReord.Code != http.StatusBadRequest {
		t.Fatalf("POST empty reorder = %d, want 400", badReord.Code)
	}
	if badReord2 := doJSON(t, h, http.MethodPost, "/api/decks/dup-deck-id/reorder", map[string]any{
		"cardIds": []string{"dup-card-id", "missing-card"},
	}); badReord2.Code != http.StatusBadRequest {
		t.Fatalf("POST missing card reorder = %d, want 400", badReord2.Code)
	}

	// 7. 500 does not leak raw database error details
	closedStore, err := store.Open(filepath.Join(t.TempDir(), "closed.db"))
	if err != nil {
		t.Fatalf("store.Open failed: %v", err)
	}
	_ = closedStore.Close()
	brokenHandler := api.NewServer(closedStore).Handler()
	errRes := doJSON(t, brokenHandler, http.MethodGet, "/api/decks", nil)
	if errRes.Code != http.StatusInternalServerError {
		t.Fatalf("GET on closed store = %d, want 500", errRes.Code)
	}
	if strings.Contains(errRes.Body.String(), "database is closed") || !strings.Contains(errRes.Body.String(), `"internal server error"`) {
		t.Fatalf("500 response leaked raw error or wrong message: %s", errRes.Body.String())
	}
}

func TestAPI_ExportAndImportAllFormats(t *testing.T) {
	h := newTestServer(t)

	initialCardsRes := doJSON(t, h, http.MethodGet, "/api/decks/deck-real-analysis/cards", nil)
	var initialCards []domain.Flashcard
	_ = json.Unmarshal(initialCardsRes.Body.Bytes(), &initialCards)
	wantCount := len(initialCards)
	if wantCount == 0 {
		t.Fatal("expected seeded cards in deck-real-analysis")
	}

	// Export seeded deck in all 4 formats
	for _, format := range []string{"json", "csv", "anki", "md"} {
		res := doJSON(t, h, http.MethodGet, "/api/decks/deck-real-analysis/export?format="+format, nil)
		if res.Code != http.StatusOK {
			t.Fatalf("GET export?format=%s = %d: %s", format, res.Code, res.Body.String())
		}
		var exported struct {
			Filename string `json:"filename"`
			Content  string `json:"content"`
			MimeType string `json:"mimeType"`
		}
		if err := json.Unmarshal(res.Body.Bytes(), &exported); err != nil {
			t.Fatalf("decode export %s: %v", format, err)
		}
		if exported.Filename == "" || exported.Content == "" || exported.MimeType == "" {
			t.Fatalf("incomplete export payload for %s: %+v", format, exported)
		}

		// Re-import into a brand new deck
		impRes := doJSON(t, h, http.MethodPost, "/api/import", map[string]any{
			"format":       format,
			"content":      exported.Content,
			"newDeckTitle": "Imported " + format,
		})
		if impRes.Code != http.StatusCreated {
			t.Fatalf("POST /api/import (%s) = %d: %s", format, impRes.Code, impRes.Body.String())
		}
		var impBody struct {
			Deck          domain.Deck        `json:"deck"`
			ImportedCount int                `json:"importedCount"`
			Cards         []domain.Flashcard `json:"cards"`
		}
		if err := json.Unmarshal(impRes.Body.Bytes(), &impBody); err != nil {
			t.Fatalf("decode import %s: %v", format, err)
		}
		if impBody.ImportedCount != wantCount || len(impBody.Cards) != wantCount || impBody.Deck.CardCount != wantCount {
			t.Fatalf("import (%s) unexpected counts: count=%d len=%d deck.CardCount=%d (want %d)",
				format, impBody.ImportedCount, len(impBody.Cards), impBody.Deck.CardCount, wantCount)
		}
	}

	// Import into an existing deck appends cards transactionally
	csvContent := "Front,Back,Topic\n\"Define compact.\",\"Every open cover has a finite subcover.\",\"Compactness\""
	appendRes := doJSON(t, h, http.MethodPost, "/api/import", map[string]any{
		"format":       "csv",
		"content":      csvContent,
		"targetDeckId": "deck-real-analysis",
	})
	if appendRes.Code != http.StatusCreated {
		t.Fatalf("POST /api/import into existing deck = %d: %s", appendRes.Code, appendRes.Body.String())
	}
	var appendBody struct {
		Deck          domain.Deck `json:"deck"`
		ImportedCount int         `json:"importedCount"`
	}
	_ = json.Unmarshal(appendRes.Body.Bytes(), &appendBody)
	if appendBody.ImportedCount != 1 || appendBody.Deck.CardCount != wantCount+1 {
		t.Fatalf("append import counts = (%d, %d), want (1, %d)", appendBody.ImportedCount, appendBody.Deck.CardCount, wantCount+1)
	}

	// Error cases
	if badFmt := doJSON(t, h, http.MethodGet, "/api/decks/deck-real-analysis/export?format=xml", nil); badFmt.Code != http.StatusBadRequest {
		t.Fatalf("unsupported export format = %d, want 400", badFmt.Code)
	}
	if missingDeck := doJSON(t, h, http.MethodGet, "/api/decks/does-not-exist/export?format=json", nil); missingDeck.Code != http.StatusNotFound {
		t.Fatalf("export missing deck = %d, want 404", missingDeck.Code)
	}
	if badImp := doJSON(t, h, http.MethodPost, "/api/import", map[string]any{"format": "csv", "content": ""}); badImp.Code != http.StatusBadRequest {
		t.Fatalf("empty import = %d, want 400", badImp.Code)
	}
	if missingTarget := doJSON(t, h, http.MethodPost, "/api/import", map[string]any{
		"format":       "csv",
		"content":      csvContent,
		"targetDeckId": "does-not-exist",
	}); missingTarget.Code != http.StatusNotFound {
		t.Fatalf("import missing targetDeckId = %d, want 404", missingTarget.Code)
	}
}

func TestAPI_StatsEndpointAndValidation(t *testing.T) {
	h := newTestServer(t)

	// Log one review and one session so streaks and daily activity are populated.
	rev := doJSON(t, h, http.MethodPost, "/api/cards/card-ra-1/review", map[string]any{"rating": 4})
	if rev.Code != http.StatusOK {
		t.Fatalf("POST review = %d: %s", rev.Code, rev.Body.String())
	}
	sess := doJSON(t, h, http.MethodPost, "/api/sessions", domain.StudySessionRecord{
		Mode:            domain.StudyModeStandard,
		DeckIDs:         []string{"deck-real-analysis"},
		DeckTitles:      []string{"Real Analysis & Calculus"},
		CardsReviewed:   1,
		CorrectCount:    1,
		DurationSeconds: 95,
	})
	if sess.Code != http.StatusCreated {
		t.Fatalf("POST session = %d: %s", sess.Code, sess.Body.String())
	}

	res := doJSON(t, h, http.MethodGet, "/api/stats", nil)
	if res.Code != http.StatusOK {
		t.Fatalf("GET /api/stats = %d: %s", res.Code, res.Body.String())
	}
	var body struct {
		TotalCards        int `json:"totalCards"`
		TotalStudySeconds int `json:"totalStudySeconds"`
		CurrentStreakDays int `json:"currentStreakDays"`
		LongestStreakDays int `json:"longestStreakDays"`
		DeckBreakdown     []any `json:"deckBreakdown"`
		DailyActivity     []struct {
			Date         string `json:"date"`
			Reviews      int    `json:"reviews"`
			Correct      int    `json:"correct"`
			StudySeconds int    `json:"studySeconds"`
		} `json:"dailyActivity"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode /api/stats: %v", err)
	}
	if body.TotalCards != 16 || body.TotalStudySeconds != 95 || body.CurrentStreakDays != 1 || body.LongestStreakDays != 1 {
		t.Fatalf("unexpected stats summary: %+v", body)
	}
	if len(body.DeckBreakdown) != 4 || len(body.DailyActivity) != 30 {
		t.Fatalf("breakdown=%d activity=%d, want 4/30", len(body.DeckBreakdown), len(body.DailyActivity))
	}
	today := body.DailyActivity[len(body.DailyActivity)-1]
	if today.Reviews != 1 || today.Correct != 1 || today.StudySeconds != 95 {
		t.Fatalf("unexpected today activity: %+v", today)
	}

	// Custom days=14
	res14 := doJSON(t, h, http.MethodGet, "/api/stats?days=14", nil)
	if res14.Code != http.StatusOK {
		t.Fatalf("GET /api/stats?days=14 = %d", res14.Code)
	}
	var body14 struct {
		DailyActivity []any `json:"dailyActivity"`
	}
	_ = json.Unmarshal(res14.Body.Bytes(), &body14)
	if len(body14.DailyActivity) != 14 {
		t.Fatalf("len(dailyActivity) for days=14 = %d, want 14", len(body14.DailyActivity))
	}

	// Invalid days values -> 400
	for _, bad := range []string{"0", "999", "-5", "abc"} {
		badRes := doJSON(t, h, http.MethodGet, "/api/stats?days="+bad, nil)
		if badRes.Code != http.StatusBadRequest {
			t.Fatalf("GET /api/stats?days=%s = %d, want 400", bad, badRes.Code)
		}
	}
}

func TestAPI_TransferCardsEndpoint(t *testing.T) {
	h := newTestServer(t)

	// Review card-ra-1 so it has SRS state and review_logs history before transfer.
	rev := doJSON(t, h, http.MethodPost, "/api/cards/card-ra-1/review", map[string]any{"rating": 4})
	if rev.Code != http.StatusOK {
		t.Fatalf("POST review = %d: %s", rev.Code, rev.Body.String())
	}
	var beforeCard domain.Flashcard
	_ = json.Unmarshal(rev.Body.Bytes(), &beforeCard)

	// Transfer card-ra-1 and card-ra-2 into deck-linear-algebra with a new chapter.
	res := doJSON(t, h, http.MethodPost, "/api/cards/transfer", domain.TransferCardsRequest{
		CardIDs:      []string{"card-ra-1", "card-ra-2"},
		TargetDeckID: "deck-linear-algebra",
		TargetTopic:  "Imported Analysis",
	})
	if res.Code != http.StatusOK {
		t.Fatalf("POST /api/cards/transfer = %d: %s", res.Code, res.Body.String())
	}
	var body struct {
		Moved int `json:"moved"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode transfer response: %v", err)
	}
	if body.Moved != 2 {
		t.Fatalf("moved = %d, want 2", body.Moved)
	}

	// Verify destination deck contains moved cards with preserved SRS history and added chapter.
	decksRes := doJSON(t, h, http.MethodGet, "/api/decks", nil)
	var decks []domain.Deck
	_ = json.Unmarshal(decksRes.Body.Bytes(), &decks)
	var targetDeck domain.Deck
	for _, d := range decks {
		if d.ID == "deck-linear-algebra" {
			targetDeck = d
		}
	}
	foundChapter := false
	for _, ch := range targetDeck.Chapters {
		if ch == "Imported Analysis" {
			foundChapter = true
		}
	}
	if !foundChapter {
		t.Fatalf("expected target deck chapters to include %q, got %v", "Imported Analysis", targetDeck.Chapters)
	}

	cardsRes := doJSON(t, h, http.MethodGet, "/api/decks/deck-linear-algebra/cards", nil)
	var cards []domain.Flashcard
	_ = json.Unmarshal(cardsRes.Body.Bytes(), &cards)
	var movedCard domain.Flashcard
	for _, c := range cards {
		if c.ID == "card-ra-1" {
			movedCard = c
		}
	}
	if movedCard.DeckID != "deck-linear-algebra" || movedCard.Topic != "Imported Analysis" {
		t.Fatalf("movedCard metadata = (%q, %q)", movedCard.DeckID, movedCard.Topic)
	}
	if movedCard.TotalReviews != beforeCard.TotalReviews || len(movedCard.History) != len(beforeCard.History) ||
		movedCard.IntervalDays != beforeCard.IntervalDays || movedCard.EaseFactor != beforeCard.EaseFactor ||
		len(movedCard.History) == 0 {
		t.Fatalf("movedCard SRS not preserved: got=%+v want=%+v", movedCard, beforeCard)
	}

	// 404 cases: missing deck or missing card.
	if r := doJSON(t, h, http.MethodPost, "/api/cards/transfer", domain.TransferCardsRequest{
		CardIDs:      []string{"card-ra-1"},
		TargetDeckID: "no-such-deck",
	}); r.Code != http.StatusNotFound {
		t.Fatalf("missing targetDeckId = %d, want 404", r.Code)
	}
	if r := doJSON(t, h, http.MethodPost, "/api/cards/transfer", domain.TransferCardsRequest{
		CardIDs:      []string{"no-such-card"},
		TargetDeckID: "deck-linear-algebra",
	}); r.Code != http.StatusNotFound {
		t.Fatalf("missing cardId = %d, want 404", r.Code)
	}

	// 400 cases: empty cardIds, duplicate cardIds, empty targetDeckId, invalid JSON.
	for _, payload := range []any{
		domain.TransferCardsRequest{CardIDs: []string{}, TargetDeckID: "deck-linear-algebra"},
		domain.TransferCardsRequest{CardIDs: []string{"card-ra-1", "card-ra-1"}, TargetDeckID: "deck-linear-algebra"},
		domain.TransferCardsRequest{CardIDs: []string{"card-ra-1"}, TargetDeckID: ""},
	} {
		if r := doJSON(t, h, http.MethodPost, "/api/cards/transfer", payload); r.Code != http.StatusBadRequest {
			t.Fatalf("invalid transfer %+v = %d, want 400", payload, r.Code)
		}
	}
	badJSONReq := httptest.NewRequest(http.MethodPost, "/api/cards/transfer", strings.NewReader("{bad"))
	badJSONRec := httptest.NewRecorder()
	h.ServeHTTP(badJSONRec, badJSONReq)
	if badJSONRec.Code != http.StatusBadRequest {
		t.Fatalf("bad JSON = %d, want 400", badJSONRec.Code)
	}
}

func TestReorderDecksAPI(t *testing.T) {
	h := newTestServer(t)

	initialRes := doJSON(t, h, http.MethodGet, "/api/decks", nil)
	var initial []domain.Deck
	if err := json.Unmarshal(initialRes.Body.Bytes(), &initial); err != nil || len(initial) < 2 {
		t.Fatalf("failed to load initial decks: %v len=%d", err, len(initial))
	}

	reversed := make([]string, len(initial))
	for i := range initial {
		reversed[i] = initial[len(initial)-1-i].ID
	}

	reorderRes := doJSON(t, h, http.MethodPost, "/api/decks/reorder", map[string]any{"deckIds": reversed})
	if reorderRes.Code != http.StatusOK {
		t.Fatalf("POST /api/decks/reorder = %d: %s", reorderRes.Code, reorderRes.Body.String())
	}

	afterRes := doJSON(t, h, http.MethodGet, "/api/decks", nil)
	var after []domain.Deck
	_ = json.Unmarshal(afterRes.Body.Bytes(), &after)
	for i := range reversed {
		if after[i].ID != reversed[i] {
			t.Fatalf("deck %d = %s, want %s", i, after[i].ID, reversed[i])
		}
	}

	// Negative targetIndex returns 400
	neg := -1
	badIdx := doJSON(t, h, http.MethodPost, "/api/cards/transfer", domain.TransferCardsRequest{
		CardIDs:      []string{"card-ra-1"},
		TargetDeckID: "deck-linear-algebra",
		TargetIndex:  &neg,
	})
	if badIdx.Code != http.StatusBadRequest {
		t.Fatalf("negative targetIndex = %d, want 400", badIdx.Code)
	}

	// Valid targetIndex = 0 places transferred card first in chapter
	zero := 0
	okIdx := doJSON(t, h, http.MethodPost, "/api/cards/transfer", domain.TransferCardsRequest{
		CardIDs:      []string{"card-ra-1"},
		TargetDeckID: "deck-real-analysis",
		TargetTopic:  "Limits & Continuity",
		TargetIndex:  &zero,
	})
	if okIdx.Code != http.StatusOK {
		t.Fatalf("indexed transfer = %d: %s", okIdx.Code, okIdx.Body.String())
	}
}
