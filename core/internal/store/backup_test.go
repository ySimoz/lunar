package store_test

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	_ "github.com/mattn/go-sqlite3"

	"lunar/core/internal/domain"
	"lunar/core/internal/store"
)

func TestBackupAndRestoreRoundTrip(t *testing.T) {
	s := openTestStore(t)

	deck, err := s.CreateDeck(domain.Deck{
		Title:      "Topology",
		Category:   domain.CategoryTopology,
		Difficulty: domain.DifficultyHard,
	})
	if err != nil {
		t.Fatalf("CreateDeck failed: %v", err)
	}
	card, err := s.CreateCard(domain.Flashcard{
		DeckID:     deck.ID,
		Front:      "Define compact space.",
		Back:       "Every open cover has a finite subcover.",
		Difficulty: domain.DifficultyMedium,
	})
	if err != nil {
		t.Fatalf("CreateCard failed: %v", err)
	}
	dur := int64(850)
	if _, err := s.ReviewCard(card.ID, 4, &dur, time.Now()); err != nil {
		t.Fatalf("ReviewCard failed: %v", err)
	}

	// Backup while WAL is active; VACUUM INTO must include recent writes.
	backupBytes, err := s.Backup()
	if err != nil {
		t.Fatalf("Backup failed: %v", err)
	}
	if len(backupBytes) < 100 {
		t.Fatalf("unexpected small backup size: %d", len(backupBytes))
	}

	// Mutate live database after backup.
	extraDeck, err := s.CreateDeck(domain.Deck{
		Title:      "Post-Backup Deck",
		Category:   domain.CategoryCalculus,
		Difficulty: domain.DifficultyEasy,
	})
	if err != nil {
		t.Fatalf("CreateDeck post-backup failed: %v", err)
	}
	if err := s.DeleteDeck(deck.ID); err != nil {
		t.Fatalf("DeleteDeck failed: %v", err)
	}

	counts, err := s.Restore(backupBytes)
	if err != nil {
		t.Fatalf("Restore failed: %v", err)
	}
	if counts.Decks != 1 || counts.Cards != 1 {
		t.Fatalf("RestoreCounts = %+v, want {Decks:1 Cards:1}", counts)
	}

	decks, err := s.ListDecks(time.Now())
	if err != nil {
		t.Fatalf("ListDecks after restore failed: %v", err)
	}
	if len(decks) != 1 || decks[0].ID != deck.ID {
		t.Fatalf("decks after restore = %+v, want original deck %s", decks, deck.ID)
	}
	if _, err := s.GetDeck(extraDeck.ID, time.Now()); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("expected post-backup deck %s to be gone, got err=%v", extraDeck.ID, err)
	}

	restoredCard, err := s.GetCard(card.ID)
	if err != nil {
		t.Fatalf("GetCard after restore failed: %v", err)
	}
	if restoredCard.TotalReviews != 1 || len(restoredCard.History) != 1 {
		t.Fatalf("review history lost after restore: total=%d history=%d", restoredCard.TotalReviews, len(restoredCard.History))
	}

	// Restored store remains writable.
	if _, err := s.CreateDeck(domain.Deck{
		Title:      "After Restore",
		Category:   domain.CategoryGeometry,
		Difficulty: domain.DifficultyEasy,
	}); err != nil {
		t.Fatalf("CreateDeck after restore failed: %v", err)
	}
}

func TestRestoreRejectsInvalidFilesAndPreservesLiveDB(t *testing.T) {
	s := openTestStore(t)
	if err := s.SeedIfEmpty(); err != nil {
		t.Fatalf("SeedIfEmpty failed: %v", err)
	}

	nonLunarDBPath := filepath.Join(t.TempDir(), "other.db")
	otherDB, err := sql.Open("sqlite3", nonLunarDBPath)
	if err != nil {
		t.Fatalf("open other db: %v", err)
	}
	if _, err := otherDB.Exec(`CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);`); err != nil {
		t.Fatalf("create table in other db: %v", err)
	}
	_ = otherDB.Close()
	nonLunarBytes, err := os.ReadFile(nonLunarDBPath)
	if err != nil {
		t.Fatalf("read other db: %v", err)
	}

	wrongSchemaPath := filepath.Join(t.TempDir(), "wrong_schema.db")
	wrongDB, err := sql.Open("sqlite3", wrongSchemaPath)
	if err != nil {
		t.Fatalf("open wrong schema db: %v", err)
	}
	if _, err := wrongDB.Exec(`
		CREATE TABLE decks (x INT);
		CREATE TABLE cards (x INT);
		CREATE TABLE review_logs (x INT);
	`); err != nil {
		t.Fatalf("create wrong schema tables: %v", err)
	}
	_ = wrongDB.Close()
	wrongSchemaBytes, err := os.ReadFile(wrongSchemaPath)
	if err != nil {
		t.Fatalf("read wrong schema db: %v", err)
	}

	corruptBytes := append([]byte("SQLite format 3\x00"), make([]byte, 200)...)
	for i := 16; i < len(corruptBytes); i++ {
		corruptBytes[i] = 0xff
	}

	cases := []struct {
		name string
		data []byte
	}{
		{"empty", nil},
		{"plain text", []byte("not a sqlite database at all")},
		{"corrupt sqlite", corruptBytes},
		{"non-lunar sqlite", nonLunarBytes},
		{"wrong lunar schema", wrongSchemaBytes},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := s.Restore(tc.data); !errors.Is(err, store.ErrValidation) {
				t.Fatalf("Restore(%s) error = %v, want ErrValidation", tc.name, err)
			}
		})
	}

	decks, err := s.ListDecks(time.Now())
	if err != nil {
		t.Fatalf("ListDecks after rejected restores failed: %v", err)
	}
	if len(decks) != 4 {
		t.Fatalf("live DB modified after rejected restores: len(decks)=%d, want 4", len(decks))
	}
}
