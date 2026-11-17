package store

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"time"

	"lunar/core/internal/domain"
)

//go:embed starter_data.json
var starterDataJSON []byte

type starterDeckSeed struct {
	ID               string                 `json:"id"`
	UserID           string                 `json:"userId"`
	Title            string                 `json:"title"`
	Description      string                 `json:"description"`
	Category         domain.SubjectCategory `json:"category"`
	Difficulty       domain.Difficulty      `json:"difficulty"`
	Color            string                 `json:"color"`
	Chapters         []string               `json:"chapters"`
	CreatedOffsetSec int64                  `json:"createdOffsetSec"`
}

type starterCardSeed struct {
	ID                  string             `json:"id"`
	DeckID              string             `json:"deckId"`
	UserID              string             `json:"userId"`
	Topic               string             `json:"topic"`
	Order               int                `json:"order"`
	CardType            domain.CardType    `json:"cardType"`
	Front               string             `json:"front"`
	Back                string             `json:"back"`
	Layers              []domain.CardLayer `json:"layers"`
	Explanation         string             `json:"explanation"`
	Difficulty          domain.Difficulty  `json:"difficulty"`
	Repetition          int                `json:"repetition"`
	IntervalDays        int                `json:"intervalDays"`
	EaseFactor          float64            `json:"easeFactor"`
	NextReviewOffsetSec int64              `json:"nextReviewOffsetSec"`
	TotalReviews        int                `json:"totalReviews"`
	CorrectCount        int                `json:"correctCount"`
	IncorrectCount      int                `json:"incorrectCount"`
	CreatedOffsetSec    int64              `json:"createdOffsetSec"`
}

type starterBundle struct {
	Decks []starterDeckSeed `json:"decks"`
	Cards []starterCardSeed `json:"cards"`
}

// SeedIfEmpty populates the 4 starter math decks and 16 LaTeX cards when the store is empty.
func (s *Store) SeedIfEmpty() error {
	var deckCount, cardCount int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM decks`).Scan(&deckCount); err != nil {
		return fmt.Errorf("count decks: %w", err)
	}
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM cards`).Scan(&cardCount); err != nil {
		return fmt.Errorf("count cards: %w", err)
	}
	if deckCount > 0 || cardCount > 0 {
		return nil
	}

	var bundle starterBundle
	if err := json.Unmarshal(starterDataJSON, &bundle); err != nil {
		return fmt.Errorf("unmarshal starter data: %w", err)
	}

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	now := time.Now().UTC()
	nowStr := now.Format(time.RFC3339)

	for _, d := range bundle.Decks {
		createdAt := now.Add(time.Duration(d.CreatedOffsetSec) * time.Second).Format(time.RFC3339)
		if _, err := tx.Exec(`
			INSERT OR IGNORE INTO decks (id, user_id, title, description, category, difficulty, color, chapters_json, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			d.ID, d.UserID, d.Title, d.Description, string(d.Category),
			string(d.Difficulty), d.Color, encodeStringSlice(d.Chapters), createdAt, nowStr,
		); err != nil {
			return fmt.Errorf("seed deck %s: %w", d.ID, err)
		}
	}

	for _, sc := range bundle.Cards {
		card := toDomainStarterCard(sc, now, nowStr)
		if err := insertCardRow(tx, card); err != nil {
			return fmt.Errorf("seed card %s: %w", sc.ID, err)
		}
		if _, err := replaceCardLayers(tx, card.ID, card.Layers); err != nil {
			return fmt.Errorf("seed layers for %s: %w", sc.ID, err)
		}
	}

	return tx.Commit()
}

func toDomainStarterCard(sc starterCardSeed, now time.Time, nowStr string) domain.Flashcard {
	return domain.Flashcard{
		ID:             sc.ID,
		DeckID:         sc.DeckID,
		UserID:         sc.UserID,
		Topic:          sc.Topic,
		Order:          sc.Order,
		CardType:       sc.CardType,
		Front:          sc.Front,
		Back:           sc.Back,
		Layers:         sc.Layers,
		Explanation:    sc.Explanation,
		Difficulty:     sc.Difficulty,
		Tags:           []string{},
		Repetition:     sc.Repetition,
		IntervalDays:   sc.IntervalDays,
		EaseFactor:     sc.EaseFactor,
		NextReviewDate: now.Add(time.Duration(sc.NextReviewOffsetSec) * time.Second).Format(time.RFC3339),
		TotalReviews:   sc.TotalReviews,
		CorrectCount:   sc.CorrectCount,
		IncorrectCount: sc.IncorrectCount,
		CreatedAt:      now.Add(time.Duration(sc.CreatedOffsetSec) * time.Second).Format(time.RFC3339),
		UpdatedAt:      nowStr,
	}
}
