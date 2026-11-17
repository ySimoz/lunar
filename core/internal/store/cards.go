package store

import (
	"database/sql"
	"errors"
	"fmt"

	"lunar/core/internal/domain"
)

const cardColumns = `id, deck_id, user_id, topic, card_order, card_type, front, back,
	explanation, difficulty, tags_json, repetition, interval_days, ease_factor,
	next_review_date, last_reviewed, total_reviews, correct_count, incorrect_count,
	created_at, updated_at`

// ListCards returns cards ordered by card_order; if deckID is non-empty, filters to that deck.
func (s *Store) ListCards(deckID string) ([]domain.Flashcard, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	query := "SELECT " + cardColumns + " FROM cards"
	var args []any
	if deckID != "" {
		query += " WHERE deck_id = ?"
		args = append(args, deckID)
	}
	query += " ORDER BY card_order ASC, created_at ASC, rowid ASC"

	rows, err := tx.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("query cards: %w", err)
	}
	defer rows.Close()

	cards := []domain.Flashcard{}
	for rows.Next() {
		c, err := scanCard(rows)
		if err != nil {
			return nil, err
		}
		cards = append(cards, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// Close rows explicitly before hydrating relations on the single SQLite connection.
	_ = rows.Close()

	for i := range cards {
		if err := hydrateCardRelations(tx, &cards[i]); err != nil {
			return nil, err
		}
	}
	return cards, nil
}

// GetCard fetches a single card along with its ordered layers and review history.
func (s *Store) GetCard(id string) (domain.Flashcard, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return domain.Flashcard{}, err
	}
	defer tx.Rollback()

	return getCard(tx, id)
}

func getCard(q queryRunner, id string) (domain.Flashcard, error) {
	row := q.QueryRow("SELECT "+cardColumns+" FROM cards WHERE id = ?", id)
	c, err := scanCard(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Flashcard{}, ErrNotFound
	}
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("query card %s: %w", id, err)
	}
	if err := hydrateCardRelations(q, &c); err != nil {
		return domain.Flashcard{}, err
	}
	return c, nil
}

// CreateCard validates and inserts a new flashcard and its ordered layers.
func (s *Store) CreateCard(card domain.Flashcard) (domain.Flashcard, error) {
	card = applyCardDefaults(card)
	if err := card.Validate(); err != nil {
		return domain.Flashcard{}, fmt.Errorf("%w: %v", ErrValidation, err)
	}

	now := nowISO()
	if card.ID == "" {
		card.ID = newID("card")
	}
	if card.NextReviewDate == "" {
		card.NextReviewDate = now
	}
	if card.CreatedAt == "" {
		card.CreatedAt = now
	}
	card.UpdatedAt = now

	tx, err := s.db.Begin()
	if err != nil {
		return domain.Flashcard{}, err
	}
	defer tx.Rollback()

	if err := requireDeckExists(tx, card.DeckID); err != nil {
		return domain.Flashcard{}, err
	}
	if err := insertCardRow(tx, card); err != nil {
		return domain.Flashcard{}, err
	}
	layers, err := replaceCardLayers(tx, card.ID, card.Layers)
	if err != nil {
		return domain.Flashcard{}, err
	}
	card.Layers = layers

	if err := tx.Commit(); err != nil {
		return domain.Flashcard{}, err
	}
	return card, nil
}

// UpdateCardContent updates content fields and layers without touching SM-2 state or review history.
func (s *Store) UpdateCardContent(id string, update domain.Flashcard) (domain.Flashcard, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return domain.Flashcard{}, err
	}
	defer tx.Rollback()

	existing, err := scanCard(tx.QueryRow("SELECT "+cardColumns+" FROM cards WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Flashcard{}, ErrNotFound
	}
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("query card %s: %w", id, err)
	}
	if update.DeckID != "" && update.DeckID != existing.DeckID {
		return domain.Flashcard{}, fmt.Errorf("%w: cannot change card deckId", ErrValidation)
	}
	if update.DeckID == "" {
		update.DeckID = existing.DeckID
	}
	update = applyCardDefaults(update)
	if err := update.Validate(); err != nil {
		return domain.Flashcard{}, fmt.Errorf("%w: %v", ErrValidation, err)
	}

	// Decoupled content update: SRS columns (repetition, interval, ease, history) remain untouched.
	res, err := tx.Exec(`
		UPDATE cards
		SET topic = ?, card_type = ?, front = ?, back = ?, explanation = ?,
		    difficulty = ?, tags_json = ?, updated_at = ?
		WHERE id = ?`,
		update.Topic, string(update.CardType), update.Front, update.Back,
		update.Explanation, string(update.Difficulty), encodeStringSlice(update.Tags),
		nowISO(), id,
	)
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("update card content %s: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("update card content %s rows affected: %w", id, err)
	}
	if n == 0 {
		return domain.Flashcard{}, ErrNotFound
	}
	if _, err := replaceCardLayers(tx, id, update.Layers); err != nil {
		return domain.Flashcard{}, err
	}
	updated, err := getCard(tx, id)
	if err != nil {
		return domain.Flashcard{}, err
	}
	if err := tx.Commit(); err != nil {
		return domain.Flashcard{}, err
	}
	return updated, nil
}

// DeleteCard removes a card and cascades to its layers and review logs.
func (s *Store) DeleteCard(id string) error {
	res, err := s.db.Exec(`DELETE FROM cards WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("delete card %s: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("delete card %s rows affected: %w", id, err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func requireDeckExists(q queryRunner, deckID string) error {
	var exists int
	err := q.QueryRow(`SELECT 1 FROM decks WHERE id = ?`, deckID).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	return err
}
