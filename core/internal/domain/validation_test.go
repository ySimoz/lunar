package domain_test

import (
	"encoding/json"
	"strings"
	"testing"

	"lunar/core/internal/domain"
)

func TestFlashcardValidate_UniqueLayerIDs(t *testing.T) {
	base := domain.Flashcard{
		DeckID:     "d1",
		Front:      "Q",
		Back:       "A",
		Difficulty: domain.DifficultyMedium,
	}

	// Multiple empty layer IDs are allowed (assigned on insert).
	withEmpty := base
	withEmpty.Layers = []domain.CardLayer{
		{Title: "Hint 1", Content: "C1"},
		{Title: "Hint 2", Content: "C2"},
	}
	if err := withEmpty.Validate(); err != nil {
		t.Fatalf("expected empty layer IDs to be valid, got: %v", err)
	}

	// Duplicate non-empty layer IDs must fail.
	withDup := base
	withDup.Layers = []domain.CardLayer{
		{ID: "dup-1", Title: "Hint 1", Content: "C1"},
		{ID: "dup-1", Title: "Hint 2", Content: "C2"},
	}
	if err := withDup.Validate(); err == nil {
		t.Fatal("expected duplicate layer IDs to fail validation")
	}
}

func TestActiveSessionAndSessionRecord_ValidationAndJSON(t *testing.T) {
	st := domain.ActiveSessionState{
		SessionID:       "s1",
		DeckIDs:         []string{},
		Mode:            domain.StudyModeStandard,
		CardIDs:         []string{"c1"},
		ReviewedCardIDs: []string{},
	}
	raw, err := json.Marshal(st)
	if err != nil {
		t.Fatalf("marshal ActiveSessionState: %v", err)
	}
	if !strings.Contains(string(raw), `"deckIds":[]`) {
		t.Fatalf("expected \"deckIds\":[] in JSON, got %s", raw)
	}

	neg := -1
	st.LivesLeft = &neg
	if err := st.Validate(); err == nil {
		t.Fatal("expected negative ActiveSessionState.LivesLeft to fail validation")
	}

	rec := domain.StudySessionRecord{
		Mode:      domain.StudyModeSurvival,
		LivesLeft: &neg,
	}
	if err := rec.Validate(); err == nil {
		t.Fatal("expected negative StudySessionRecord.LivesLeft to fail validation")
	}
}

func TestPreferencesValidate_ThemeRetroUIFontClockStyle(t *testing.T) {
	p := domain.DefaultPreferences()
	if err := p.Validate(); err != nil {
		t.Fatalf("DefaultPreferences().Validate() failed: %v", err)
	}

	badTheme := p
	badTheme.Theme = "invalid-theme"
	if err := badTheme.Validate(); err == nil {
		t.Error("expected invalid theme to fail validation")
	}

	badRetro := p
	badRetro.RetroUIFont = "comic-sans"
	if err := badRetro.Validate(); err == nil {
		t.Error("expected invalid retroUIFont to fail validation")
	}

	badClock := p
	badClock.ClockStyle = "sundial"
	if err := badClock.Validate(); err == nil {
		t.Error("expected invalid clockStyle to fail validation")
	}
}

func TestTransferCardsRequest_Validate(t *testing.T) {
	valid := domain.TransferCardsRequest{
		CardIDs:      []string{"c1", "c2"},
		TargetDeckID: "d2",
		TargetTopic:  "Chapters",
	}
	if err := valid.Validate(); err != nil {
		t.Fatalf("expected valid TransferCardsRequest, got: %v", err)
	}

	cases := []struct {
		name string
		req  domain.TransferCardsRequest
	}{
		{"empty targetDeckId", domain.TransferCardsRequest{CardIDs: []string{"c1"}, TargetDeckID: "  "}},
		{"empty cardIds", domain.TransferCardsRequest{CardIDs: []string{}, TargetDeckID: "d2"}},
		{"blank cardId", domain.TransferCardsRequest{CardIDs: []string{"c1", " "}, TargetDeckID: "d2"}},
		{"duplicate cardIds", domain.TransferCardsRequest{CardIDs: []string{"c1", "c1"}, TargetDeckID: "d2"}},
		{"duplicate trimmed cardIds", domain.TransferCardsRequest{CardIDs: []string{"c1", " c1 "}, TargetDeckID: "d2"}},
	}
	for _, tc := range cases {
		if err := tc.req.Validate(); err == nil {
			t.Errorf("%s: expected validation error, got nil", tc.name)
		}
	}
}
