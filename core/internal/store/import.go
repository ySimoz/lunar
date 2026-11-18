package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"lunar/core/internal/domain"
)

// BulkImport atomically imports cards into targetDeckID, or creates newDeck first when targetDeckID is empty.
func (s *Store) BulkImport(targetDeckID string, newDeck *domain.Deck, cards []domain.Flashcard) (domain.Deck, []domain.Flashcard, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(cards) == 0 {
		return domain.Deck{}, nil, fmt.Errorf("%w: no cards to import", ErrValidation)
	}

	tx, err := s.db.Begin()
	if err != nil {
		return domain.Deck{}, nil, err
	}
	defer tx.Rollback()

	var deck domain.Deck
	var nextOrder int
	now := nowISO()

	if targetDeckID != "" {
		row := tx.QueryRow(`
			SELECT id, user_id, title, description, category, difficulty, color, chapters_json, created_at, updated_at
			FROM decks WHERE id = ?`, targetDeckID)
		deck, err = scanDeck(row)
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Deck{}, nil, ErrNotFound
		}
		if err != nil {
			return domain.Deck{}, nil, fmt.Errorf("query target deck %s: %w", targetDeckID, err)
		}
		if err := tx.QueryRow(`SELECT COALESCE(MAX(card_order), -1) + 1 FROM cards WHERE deck_id = ?`, targetDeckID).Scan(&nextOrder); err != nil {
			return domain.Deck{}, nil, fmt.Errorf("query max card_order for deck %s: %w", targetDeckID, err)
		}
	} else {
		if newDeck == nil {
			return domain.Deck{}, nil, fmt.Errorf("%w: targetDeckId or new deck metadata is required", ErrValidation)
		}
		deck = applyDeckDefaults(*newDeck)
		if err := deck.Validate(); err != nil {
			return domain.Deck{}, nil, fmt.Errorf("%w: %v", ErrValidation, err)
		}
		if deck.ID == "" {
			deck.ID = newID("deck")
		}
		if deck.CreatedAt == "" {
			deck.CreatedAt = now
		}
		deck.UpdatedAt = now
		if _, err := tx.Exec(`
			INSERT INTO decks (id, user_id, title, description, category, difficulty, color, chapters_json, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			deck.ID, deck.UserID, deck.Title, deck.Description, string(deck.Category),
			string(deck.Difficulty), deck.Color, encodeStringSlice(deck.Chapters),
			deck.CreatedAt, deck.UpdatedAt,
		); err != nil {
			return domain.Deck{}, nil, fmt.Errorf("insert imported deck: %w", err)
		}
	}

	saved := make([]domain.Flashcard, 0, len(cards))
	for i, c := range cards {
		c.ID = newID("card")
		c.DeckID = deck.ID
		c.Order = nextOrder + i
		c = applyCardDefaults(c)
		if c.NextReviewDate == "" {
			c.NextReviewDate = now
		}
		if c.CreatedAt == "" {
			c.CreatedAt = now
		}
		c.UpdatedAt = now

		layersCopy := make([]domain.CardLayer, len(c.Layers))
		for j, l := range c.Layers {
			l.ID = newID("layer")
			layersCopy[j] = l
		}
		c.Layers = layersCopy

		if err := c.Validate(); err != nil {
			return domain.Deck{}, nil, fmt.Errorf("%w: card %d: %v", ErrValidation, i+1, err)
		}
		if err := insertCardRow(tx, c); err != nil {
			return domain.Deck{}, nil, fmt.Errorf("insert imported card %d: %w", i+1, err)
		}
		insertedLayers, err := replaceCardLayers(tx, c.ID, c.Layers)
		if err != nil {
			return domain.Deck{}, nil, err
		}
		c.Layers = insertedLayers
		saved = append(saved, c)
	}

	counts, err := computeDeckCounts(tx, time.Now(), deck.ID)
	if err != nil {
		return domain.Deck{}, nil, err
	}
	c := counts[deck.ID]
	deck.CardCount, deck.DueCount = c.total, c.due

	if err := tx.Commit(); err != nil {
		return domain.Deck{}, nil, err
	}
	return deck, saved, nil
}
