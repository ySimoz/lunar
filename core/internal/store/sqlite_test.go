package store_test

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"lunar/core/internal/domain"
	"lunar/core/internal/store"
)

func openTestStore(t *testing.T) *store.Store {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "lunar_test.db")
	s, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open(%q) failed: %v", dbPath, err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestOpen_PragmasAndSeedIdempotency(t *testing.T) {
	s := openTestStore(t)

	var fk int
	if err := s.DB().QueryRow("PRAGMA foreign_keys;").Scan(&fk); err != nil || fk != 1 {
		t.Fatalf("PRAGMA foreign_keys = (%d, %v), want 1", fk, err)
	}
	var mode string
	if err := s.DB().QueryRow("PRAGMA journal_mode;").Scan(&mode); err != nil || mode != "wal" {
		t.Fatalf("PRAGMA journal_mode = (%q, %v), want wal", mode, err)
	}

	if err := s.SeedIfEmpty(); err != nil {
		t.Fatalf("SeedIfEmpty() #1 failed: %v", err)
	}
	if err := s.SeedIfEmpty(); err != nil {
		t.Fatalf("SeedIfEmpty() #2 failed: %v", err)
	}

	decks, err := s.ListDecks(time.Now())
	if err != nil {
		t.Fatalf("ListDecks() failed: %v", err)
	}
	if len(decks) != 4 {
		t.Fatalf("len(decks) = %d, want 4", len(decks))
	}

	cards, err := s.ListCards("")
	if err != nil {
		t.Fatalf("ListCards() failed: %v", err)
	}
	if len(cards) != 16 {
		t.Fatalf("len(cards) = %d, want 16", len(cards))
	}

	var totalCards int
	for _, d := range decks {
		totalCards += d.CardCount
		if d.CardCount == 0 {
			t.Errorf("deck %q has CardCount 0", d.ID)
		}
	}
	if totalCards != 16 {
		t.Errorf("sum of deck CardCount = %d, want 16", totalCards)
	}
}

func TestDeckAndCardCascadeDelete(t *testing.T) {
	s := openTestStore(t)

	deck, err := s.CreateDeck(domain.Deck{
		Title:       "Measure Theory",
		Description: "Sigma algebras and Lebesgue integration",
		Category:    domain.CategoryRealAnalysis,
		Difficulty:  domain.DifficultyHard,
		Color:       "indigo",
		Chapters:    []string{"Measures", "Integrals"},
	})
	if err != nil {
		t.Fatalf("CreateDeck failed: %v", err)
	}

	card, err := s.CreateCard(domain.Flashcard{
		DeckID:     deck.ID,
		Topic:      "Measures",
		CardType:   domain.CardTypeDefinition,
		Front:      "Define a $\\sigma$-algebra.",
		Back:       "Closed under complements and countable unions.",
		Difficulty: domain.DifficultyMedium,
		Tags:       []string{"measure"},
		Layers: []domain.CardLayer{
			{ID: "l1", Title: "Hint 1", Content: "Contains empty set"},
			{ID: "l2", Title: "Hint 2", Content: "Closed under complement"},
		},
	})
	if err != nil {
		t.Fatalf("CreateCard failed: %v", err)
	}

	dur := int64(850)
	if _, err := s.ReviewCard(card.ID, 3, &dur, time.Now()); err != nil {
		t.Fatalf("ReviewCard failed: %v", err)
	}

	if err := s.DeleteDeck(deck.ID); err != nil {
		t.Fatalf("DeleteDeck failed: %v", err)
	}

	for _, table := range []string{"cards", "card_layers", "review_logs"} {
		var count int
		if err := s.DB().QueryRow("SELECT COUNT(*) FROM " + table).Scan(&count); err != nil {
			t.Fatalf("count %s failed: %v", table, err)
		}
		if count != 0 {
			t.Errorf("orphaned rows in %s after deck delete: got %d, want 0", table, count)
		}
	}
}

func TestDecoupledCardContentUpdatePreservesSRS(t *testing.T) {
	s := openTestStore(t)

	deck, err := s.CreateDeck(domain.Deck{
		Title:      "Algebra",
		Category:   domain.CategoryAbstractAlgebra,
		Difficulty: domain.DifficultyMedium,
	})
	if err != nil {
		t.Fatalf("CreateDeck failed: %v", err)
	}

	created, err := s.CreateCard(domain.Flashcard{
		DeckID:     deck.ID,
		Front:      "Old Front",
		Back:       "Old Back",
		Difficulty: domain.DifficultyEasy,
		Layers:     []domain.CardLayer{{ID: "l1", Title: "Step 1", Content: "Old step"}},
	})
	if err != nil {
		t.Fatalf("CreateCard failed: %v", err)
	}

	reviewedAt := time.Date(2026, 11, 17, 12, 0, 0, 0, time.UTC)
	reviewed, err := s.ReviewCard(created.ID, 4, nil, reviewedAt)
	if err != nil {
		t.Fatalf("ReviewCard failed: %v", err)
	}

	updated, err := s.UpdateCardContent(created.ID, domain.Flashcard{
		DeckID:      deck.ID,
		Topic:       "Groups",
		CardType:    domain.CardTypeTheorem,
		Front:       "New Front",
		Back:        "New Back",
		Explanation: "Added proof note",
		Difficulty:  domain.DifficultyHard,
		Tags:        []string{"groups", "sylow"},
		Layers: []domain.CardLayer{
			{ID: "l2", Title: "Step A", Content: "Updated step A"},
			{ID: "l3", Title: "Step B", Content: "Updated step B"},
		},
	})
	if err != nil {
		t.Fatalf("UpdateCardContent failed: %v", err)
	}

	if updated.Front != "New Front" || updated.Back != "New Back" || len(updated.Layers) != 2 {
		t.Fatalf("content not updated properly: %+v", updated)
	}
	if updated.Repetition != reviewed.Repetition ||
		updated.IntervalDays != reviewed.IntervalDays ||
		updated.EaseFactor != reviewed.EaseFactor ||
		updated.NextReviewDate != reviewed.NextReviewDate ||
		updated.TotalReviews != reviewed.TotalReviews ||
		updated.CorrectCount != reviewed.CorrectCount ||
		len(updated.History) != 1 {
		t.Fatalf("SRS state was clobbered: got %+v, want %+v", updated, reviewed)
	}
}

func TestReorderCardsAndDueCounts(t *testing.T) {
	s := openTestStore(t)
	now := time.Date(2026, 11, 17, 10, 0, 0, 0, time.UTC)

	deck, err := s.CreateDeck(domain.Deck{
		Title:      "Topology",
		Category:   domain.CategoryTopology,
		Difficulty: domain.DifficultyMaster,
	})
	if err != nil {
		t.Fatalf("CreateDeck failed: %v", err)
	}

	c1, _ := s.CreateCard(domain.Flashcard{DeckID: deck.ID, Front: "F1", Back: "B1", Difficulty: domain.DifficultyEasy})
	c2, _ := s.CreateCard(domain.Flashcard{DeckID: deck.ID, Front: "F2", Back: "B2", Difficulty: domain.DifficultyEasy})
	// Review c1 so it is scheduled in the future
	if _, err := s.ReviewCard(c1.ID, 4, nil, now); err != nil {
		t.Fatalf("ReviewCard failed: %v", err)
	}

	decks, err := s.ListDecks(now)
	if err != nil {
		t.Fatalf("ListDecks failed: %v", err)
	}
	if decks[0].CardCount != 2 || decks[0].DueCount != 1 {
		t.Fatalf("deck counts = (%d, %d), want (2, 1)", decks[0].CardCount, decks[0].DueCount)
	}

	if err := s.ReorderCards(deck.ID, []string{c2.ID, c1.ID}); err != nil {
		t.Fatalf("ReorderCards failed: %v", err)
	}
	cards, err := s.ListCards(deck.ID)
	if err != nil {
		t.Fatalf("ListCards failed: %v", err)
	}
	if cards[0].ID != c2.ID || cards[1].ID != c1.ID {
		t.Fatalf("reordered IDs = [%s, %s], want [%s, %s]", cards[0].ID, cards[1].ID, c2.ID, c1.ID)
	}
}

func TestSessionsActiveSessionAndPreferences(t *testing.T) {
	s := openTestStore(t)

	rec, err := s.CreateSession(domain.StudySessionRecord{
		Mode:            domain.StudyModeSurvival,
		DeckIDs:         []string{"d1"},
		DeckTitles:      []string{"Real Analysis"},
		CardsReviewed:   10,
		CorrectCount:    8,
		IncorrectCount:  2,
		DurationSeconds: 180,
	})
	if err != nil {
		t.Fatalf("CreateSession failed: %v", err)
	}
	sessions, err := s.ListSessions()
	if err != nil || len(sessions) != 1 || sessions[0].ID != rec.ID {
		t.Fatalf("ListSessions = (%+v, %v), want 1 record", sessions, err)
	}

	if _, err := s.GetActiveSession(); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("GetActiveSession before save = %v, want ErrNotFound", err)
	}

	lives := 2
	saved, err := s.SaveActiveSession(domain.ActiveSessionState{
		SessionID:       "sess-1",
		DeckID:          "d1",
		Mode:            domain.StudyModeStandard,
		CurrentIndex:    1,
		CardIDs:         []string{"c1", "c2"},
		ReviewedCardIDs: []string{"c1"},
		CorrectCount:    1,
		LivesLeft:       &lives,
		StartedAt:       time.Now().UTC().Format(time.RFC3339),
	})
	if err != nil {
		t.Fatalf("SaveActiveSession failed: %v", err)
	}
	loaded, err := s.GetActiveSession()
	if err != nil || loaded.SessionID != saved.SessionID || loaded.CurrentIndex != 1 {
		t.Fatalf("GetActiveSession = (%+v, %v)", loaded, err)
	}
	if err := s.ClearActiveSession(); err != nil {
		t.Fatalf("ClearActiveSession failed: %v", err)
	}
	if _, err := s.GetActiveSession(); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("GetActiveSession after clear = %v, want ErrNotFound", err)
	}

	prefs, err := s.GetPreferences()
	if err != nil || prefs.FontFamily != "serif" {
		t.Fatalf("default GetPreferences = (%+v, %v)", prefs, err)
	}
	prefs.FontFamily = "mono"
	prefs.AutoRevealSteps = true
	updatedPrefs, err := s.UpdatePreferences(prefs)
	if err != nil || updatedPrefs.FontFamily != "mono" || !updatedPrefs.AutoRevealSteps {
		t.Fatalf("UpdatePreferences = (%+v, %v)", updatedPrefs, err)
	}
}

func TestOpen_MemoryAndPerConnectionPragmas(t *testing.T) {
	mem, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("Open(:memory:) failed: %v", err)
	}
	defer mem.Close()

	var fk, busy int
	if err := mem.DB().QueryRow("PRAGMA foreign_keys;").Scan(&fk); err != nil || fk != 1 {
		t.Fatalf(":memory: foreign_keys = (%d, %v), want 1", fk, err)
	}
	if err := mem.DB().QueryRow("PRAGMA busy_timeout;").Scan(&busy); err != nil || busy != 5000 {
		t.Fatalf(":memory: busy_timeout = (%d, %v), want 5000", busy, err)
	}

	// Verify a freshly opened connection on a file DB retains per-connection pragmas via DSN.
	s := openTestStore(t)
	s.DB().SetMaxOpenConns(2)
	ctx := context.Background()
	c1, err := s.DB().Conn(ctx)
	if err != nil {
		t.Fatalf("Conn 1 failed: %v", err)
	}
	defer c1.Close()
	c2, err := s.DB().Conn(ctx)
	if err != nil {
		t.Fatalf("Conn 2 failed: %v", err)
	}
	defer c2.Close()

	for idx, conn := range []struct {
		name string
		row  func(string) *int
	}{
		{"c1", func(q string) *int { var v int; _ = c1.QueryRowContext(ctx, q).Scan(&v); return &v }},
		{"c2", func(q string) *int { var v int; _ = c2.QueryRowContext(ctx, q).Scan(&v); return &v }},
	} {
		if got := *conn.row("PRAGMA foreign_keys;"); got != 1 {
			t.Fatalf("conn %d (%s) foreign_keys = %d, want 1", idx, conn.name, got)
		}
		if got := *conn.row("PRAGMA busy_timeout;"); got != 5000 {
			t.Fatalf("conn %d (%s) busy_timeout = %d, want 5000", idx, conn.name, got)
		}
	}
}

func TestReorderCards_ValidationAndAtomicity(t *testing.T) {
	s := openTestStore(t)
	d1, _ := s.CreateDeck(domain.Deck{Title: "Deck 1", Category: domain.CategoryCalculus, Difficulty: domain.DifficultyEasy})
	d2, _ := s.CreateDeck(domain.Deck{Title: "Deck 2", Category: domain.CategoryGeometry, Difficulty: domain.DifficultyEasy})
	c1, _ := s.CreateCard(domain.Flashcard{DeckID: d1.ID, Order: 0, Front: "Q1", Back: "A1", Difficulty: domain.DifficultyEasy})
	c2, _ := s.CreateCard(domain.Flashcard{DeckID: d1.ID, Order: 1, Front: "Q2", Back: "A2", Difficulty: domain.DifficultyEasy})
	other, _ := s.CreateCard(domain.Flashcard{DeckID: d2.ID, Front: "Other", Back: "Other", Difficulty: domain.DifficultyEasy})

	if err := s.ReorderCards("missing-deck", []string{c1.ID}); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("ReorderCards missing deck = %v, want ErrNotFound", err)
	}
	if err := s.ReorderCards(d1.ID, nil); !errors.Is(err, store.ErrValidation) {
		t.Fatalf("ReorderCards empty = %v, want ErrValidation", err)
	}
	if err := s.ReorderCards(d1.ID, []string{c1.ID, c1.ID}); !errors.Is(err, store.ErrValidation) {
		t.Fatalf("ReorderCards duplicate = %v, want ErrValidation", err)
	}
	// Cross-deck card after valid card must roll back earlier update atomically.
	if err := s.ReorderCards(d1.ID, []string{c2.ID, other.ID}); !errors.Is(err, store.ErrValidation) {
		t.Fatalf("ReorderCards cross-deck = %v, want ErrValidation", err)
	}
	if err := s.ReorderCards(d1.ID, []string{c2.ID, "missing-card"}); !errors.Is(err, store.ErrValidation) {
		t.Fatalf("ReorderCards missing card = %v, want ErrValidation", err)
	}

	cards, err := s.ListCards(d1.ID)
	if err != nil {
		t.Fatalf("ListCards failed: %v", err)
	}
	if cards[0].ID != c1.ID || cards[1].ID != c2.ID {
		t.Fatalf("expected order preserved after failed reorder, got [%s, %s]", cards[0].ID, cards[1].ID)
	}
}

func TestReviewCard_AtomicityErrorsAndGetDeckCounts(t *testing.T) {
	s := openTestStore(t)
	now := time.Date(2026, 11, 17, 10, 0, 0, 0, time.UTC)

	if _, err := s.ReviewCard("missing-card", 3, nil, now); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("ReviewCard missing = %v, want ErrNotFound", err)
	}

	d1, _ := s.CreateDeck(domain.Deck{Title: "D1", Category: domain.CategoryCalculus, Difficulty: domain.DifficultyEasy})
	d2, _ := s.CreateDeck(domain.Deck{Title: "D2", Category: domain.CategoryTopology, Difficulty: domain.DifficultyEasy})
	c1, _ := s.CreateCard(domain.Flashcard{DeckID: d1.ID, Front: "Q1", Back: "A1", Difficulty: domain.DifficultyEasy})
	_, _ = s.CreateCard(domain.Flashcard{DeckID: d2.ID, Front: "Q2", Back: "A2", Difficulty: domain.DifficultyEasy})

	neg := int64(-5)
	if _, err := s.ReviewCard(c1.ID, 3, &neg, now); !errors.Is(err, store.ErrValidation) {
		t.Fatalf("ReviewCard negative duration = %v, want ErrValidation", err)
	}

	// Concurrent reviews must not lose updates.
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func(step int) {
			defer wg.Done()
			if _, err := s.ReviewCard(c1.ID, 3, nil, now.Add(time.Duration(step)*time.Second)); err != nil {
				t.Errorf("concurrent ReviewCard %d failed: %v", step, err)
			}
		}(i)
	}
	wg.Wait()

	got, err := s.GetCard(c1.ID)
	if err != nil {
		t.Fatalf("GetCard failed: %v", err)
	}
	if got.TotalReviews != 4 || len(got.History) != 4 {
		t.Fatalf("TotalReviews=%d len(History)=%d, want 4/4", got.TotalReviews, len(got.History))
	}

	// GetDeck counts only cards belonging to d1 (1 total, 0 due after review).
	deck1, err := s.GetDeck(d1.ID, now)
	if err != nil {
		t.Fatalf("GetDeck(d1) failed: %v", err)
	}
	if deck1.CardCount != 1 || deck1.DueCount != 0 {
		t.Fatalf("GetDeck(d1) counts = (%d, %d), want (1, 0)", deck1.CardCount, deck1.DueCount)
	}

	// UpdateCardContent rejects changing DeckID.
	if _, err := s.UpdateCardContent(c1.ID, domain.Flashcard{
		DeckID:     d2.ID,
		Front:      "Q1",
		Back:       "A1",
		Difficulty: domain.DifficultyEasy,
	}); !errors.Is(err, store.ErrValidation) {
		t.Fatalf("UpdateCardContent cross-deck = %v, want ErrValidation", err)
	}
}

func TestPreferencesDefaultsAndSessionEmptyDeckIDs(t *testing.T) {
	s := openTestStore(t)

	// Empty Theme, RetroUIFont, ColorMode, ClockStyle are defaulted in UpdatePreferences.
	saved, err := s.UpdatePreferences(domain.UserPreferences{
		FontFamily: "sans",
		FontSize:   "lg",
	})
	if err != nil {
		t.Fatalf("UpdatePreferences with defaults failed: %v", err)
	}
	if saved.Theme != "lunar-emerald" || saved.RetroUIFont != "share-tech" || saved.ClockStyle != "circular" || saved.ColorMode != "dark" {
		t.Fatalf("unexpected defaulted preferences: %+v", saved)
	}

	// Invalid Theme / RetroUIFont / ClockStyle rejected.
	if _, err := s.UpdatePreferences(domain.UserPreferences{
		FontFamily: "serif",
		FontSize:   "base",
		Theme:      "not-a-theme",
	}); !errors.Is(err, store.ErrValidation) {
		t.Fatalf("invalid Theme = %v, want ErrValidation", err)
	}

	// SaveActiveSession normalizes nil DeckIDs to non-nil empty slice.
	active, err := s.SaveActiveSession(domain.ActiveSessionState{
		SessionID: "sess-empty-decks",
		Mode:      domain.StudyModeStandard,
	})
	if err != nil {
		t.Fatalf("SaveActiveSession failed: %v", err)
	}
	if active.DeckIDs == nil || len(active.DeckIDs) != 0 {
		t.Fatalf("active.DeckIDs = %#v, want non-nil empty slice", active.DeckIDs)
	}
}

func TestTransferCards_CrossDeckPreservesSRSAndAtomicity(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()

	src, err := s.CreateDeck(domain.Deck{
		Title:      "Source Deck",
		Category:   domain.CategoryCalculus,
		Difficulty: domain.DifficultyEasy,
		Chapters:   []string{"Limits"},
	})
	if err != nil {
		t.Fatalf("CreateDeck src failed: %v", err)
	}
	dst, err := s.CreateDeck(domain.Deck{
		Title:      "Target Deck",
		Category:   domain.CategoryRealAnalysis,
		Difficulty: domain.DifficultyMedium,
		Chapters:   []string{"Sequences"},
	})
	if err != nil {
		t.Fatalf("CreateDeck dst failed: %v", err)
	}

	// Existing card in destination with card_order = 0 so transferred cards get 1, 2.
	existingDst, err := s.CreateCard(domain.Flashcard{
		DeckID:     dst.ID,
		Topic:      "Sequences",
		Order:      0,
		Front:      "Existing Q",
		Back:       "Existing A",
		Difficulty: domain.DifficultyEasy,
	})
	if err != nil {
		t.Fatalf("CreateCard existingDst failed: %v", err)
	}

	c1, err := s.CreateCard(domain.Flashcard{
		DeckID:     src.ID,
		Topic:      "Limits",
		Order:      0,
		Front:      "Q1",
		Back:       "A1",
		Difficulty: domain.DifficultyMedium,
		Layers:     []domain.CardLayer{{ID: "l1", Title: "Hint", Content: "Epsilon-delta"}},
	})
	if err != nil {
		t.Fatalf("CreateCard c1 failed: %v", err)
	}
	c2, err := s.CreateCard(domain.Flashcard{
		DeckID:     src.ID,
		Topic:      "Limits",
		Order:      1,
		Front:      "Q2",
		Back:       "A2",
		Difficulty: domain.DifficultyHard,
	})
	if err != nil {
		t.Fatalf("CreateCard c2 failed: %v", err)
	}

	dur := int64(900)
	reviewedAt := time.Date(2026, 11, 17, 14, 0, 0, 0, time.UTC)
	reviewedC1, err := s.ReviewCard(c1.ID, 4, &dur, reviewedAt)
	if err != nil {
		t.Fatalf("ReviewCard c1 failed: %v", err)
	}

	// Missing target deck -> ErrNotFound, source cards untouched.
	if _, err := s.TransferCards(ctx, domain.TransferCardsRequest{
		CardIDs:      []string{c1.ID},
		TargetDeckID: "missing-deck",
		TargetTopic:  "New Chapter",
	}); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("TransferCards missing deck = %v, want ErrNotFound", err)
	}

	// Second card missing -> ErrNotFound, whole transaction rolls back (c1 stays in src, chapter not added).
	if _, err := s.TransferCards(ctx, domain.TransferCardsRequest{
		CardIDs:      []string{c1.ID, "missing-card"},
		TargetDeckID: dst.ID,
		TargetTopic:  "ShouldRollback",
	}); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("TransferCards missing card = %v, want ErrNotFound", err)
	}
	dstAfterRollback, _ := s.GetDeck(dst.ID, reviewedAt)
	if len(dstAfterRollback.Chapters) != 1 || dstAfterRollback.CardCount != 1 {
		t.Fatalf("dst mutated on rolled back transfer: %+v", dstAfterRollback)
	}

	// Invalid requests -> ErrValidation.
	if _, err := s.TransferCards(ctx, domain.TransferCardsRequest{
		CardIDs:      []string{c1.ID, c1.ID},
		TargetDeckID: dst.ID,
	}); !errors.Is(err, store.ErrValidation) {
		t.Fatalf("TransferCards duplicate ids = %v, want ErrValidation", err)
	}

	// Transfer c1 and c2 into dst under a brand-new chapter "Continuity".
	moved, err := s.TransferCards(ctx, domain.TransferCardsRequest{
		CardIDs:      []string{c1.ID, c2.ID},
		TargetDeckID: dst.ID,
		TargetTopic:  "Continuity",
	})
	if err != nil {
		t.Fatalf("TransferCards failed: %v", err)
	}
	if moved != 2 {
		t.Fatalf("moved = %d, want 2", moved)
	}

	// Target deck chapters updated without duplicating existing chapters, counts updated.
	updatedDst, err := s.GetDeck(dst.ID, reviewedAt)
	if err != nil {
		t.Fatalf("GetDeck dst failed: %v", err)
	}
	if len(updatedDst.Chapters) != 2 || updatedDst.Chapters[0] != "Sequences" || updatedDst.Chapters[1] != "Continuity" {
		t.Fatalf("dst.Chapters = %v, want [Sequences Continuity]", updatedDst.Chapters)
	}
	if updatedDst.CardCount != 3 {
		t.Fatalf("dst.CardCount = %d, want 3", updatedDst.CardCount)
	}

	updatedSrc, err := s.GetDeck(src.ID, reviewedAt)
	if err != nil {
		t.Fatalf("GetDeck src failed: %v", err)
	}
	if updatedSrc.CardCount != 0 {
		t.Fatalf("src.CardCount = %d, want 0", updatedSrc.CardCount)
	}

	// Verify order and preserved SRS state + review_logs + layers on c1.
	gotC1, err := s.GetCard(c1.ID)
	if err != nil {
		t.Fatalf("GetCard c1 failed: %v", err)
	}
	if gotC1.DeckID != dst.ID || gotC1.Topic != "Continuity" || gotC1.Order != existingDst.Order+1 {
		t.Fatalf("c1 metadata mismatch: deck=%q topic=%q order=%d", gotC1.DeckID, gotC1.Topic, gotC1.Order)
	}
	if gotC1.Repetition != reviewedC1.Repetition ||
		gotC1.IntervalDays != reviewedC1.IntervalDays ||
		gotC1.EaseFactor != reviewedC1.EaseFactor ||
		gotC1.NextReviewDate != reviewedC1.NextReviewDate ||
		gotC1.TotalReviews != 1 ||
		gotC1.CorrectCount != 1 ||
		len(gotC1.History) != 1 ||
		len(gotC1.Layers) != 1 {
		t.Fatalf("c1 SRS/relations not preserved: %+v vs %+v", gotC1, reviewedC1)
	}

	gotC2, err := s.GetCard(c2.ID)
	if err != nil {
		t.Fatalf("GetCard c2 failed: %v", err)
	}
	if gotC2.DeckID != dst.ID || gotC2.Topic != "Continuity" || gotC2.Order != existingDst.Order+2 {
		t.Fatalf("c2 metadata mismatch: deck=%q topic=%q order=%d", gotC2.DeckID, gotC2.Topic, gotC2.Order)
	}

	// Transferring again to an existing chapter ("Sequences") must not duplicate chapter entry.
	if _, err := s.TransferCards(ctx, domain.TransferCardsRequest{
		CardIDs:      []string{c2.ID},
		TargetDeckID: dst.ID,
		TargetTopic:  "Sequences",
	}); err != nil {
		t.Fatalf("TransferCards same-deck chapter move failed: %v", err)
	}
	dstAfterSameDeck, _ := s.GetDeck(dst.ID, reviewedAt)
	if len(dstAfterSameDeck.Chapters) != 2 {
		t.Fatalf("expected chapters length 2 without duplicate, got %v", dstAfterSameDeck.Chapters)
	}
}

func TestReorderDecks(t *testing.T) {
	s := openTestStore(t)
	d1, err := s.CreateDeck(domain.Deck{Title: "First"})
	if err != nil {
		t.Fatalf("CreateDeck d1: %v", err)
	}
	d2, err := s.CreateDeck(domain.Deck{Title: "Second"})
	if err != nil {
		t.Fatalf("CreateDeck d2: %v", err)
	}
	d3, err := s.CreateDeck(domain.Deck{Title: "Third"})
	if err != nil {
		t.Fatalf("CreateDeck d3: %v", err)
	}

	if err := s.ReorderDecks([]string{d3.ID, d1.ID}); err != nil {
		t.Fatalf("ReorderDecks: %v", err)
	}

	decks, err := s.ListDecks(time.Now())
	if err != nil {
		t.Fatalf("ListDecks: %v", err)
	}
	if len(decks) != 3 || decks[0].ID != d3.ID || decks[1].ID != d1.ID || decks[2].ID != d2.ID {
		t.Fatalf("unexpected deck order: %+v", decks)
	}
}

func TestTransferCardsWithTargetIndex(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	deck, err := s.CreateDeck(domain.Deck{Title: "Calc", Chapters: []string{"Limits", "Derivatives"}})
	if err != nil {
		t.Fatalf("CreateDeck: %v", err)
	}
	c1, _ := s.CreateCard(domain.Flashcard{DeckID: deck.ID, Topic: "Limits", Front: "L1", Back: "A1"})
	c2, _ := s.CreateCard(domain.Flashcard{DeckID: deck.ID, Topic: "Limits", Front: "L2", Back: "A2"})
	c3, _ := s.CreateCard(domain.Flashcard{DeckID: deck.ID, Topic: "Derivatives", Front: "D1", Back: "B1"})

	idx := 1
	if _, err := s.TransferCards(ctx, domain.TransferCardsRequest{
		CardIDs:      []string{c3.ID},
		TargetDeckID: deck.ID,
		TargetTopic:  "Limits",
		TargetIndex:  &idx,
	}); err != nil {
		t.Fatalf("TransferCards with TargetIndex: %v", err)
	}

	cards, err := s.ListCards(deck.ID)
	if err != nil {
		t.Fatalf("ListCards: %v", err)
	}
	if len(cards) != 3 || cards[0].ID != c1.ID || cards[1].ID != c3.ID || cards[2].ID != c2.ID {
		t.Fatalf("unexpected card order after indexed transfer: %+v", cards)
	}
	if cards[1].Topic != "Limits" {
		t.Fatalf("expected moved card topic Limits, got %q", cards[1].Topic)
	}
}
