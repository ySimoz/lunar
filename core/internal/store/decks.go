package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"lunar/core/internal/domain"
	"lunar/core/internal/srs"
)

type deckCounts struct {
	total int
	due   int
}

// ListDecks returns all decks ordered by creation time with computed cardCount and dueCount.
func (s *Store) ListDecks(now time.Time) ([]domain.Deck, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	counts, err := computeDeckCounts(s.db, now, "")
	if err != nil {
		return nil, err
	}

	rows, err := s.db.Query(`
		SELECT id, user_id, title, description, category, difficulty, color, chapters_json, created_at, updated_at
		FROM decks
		ORDER BY deck_order ASC, created_at ASC, id ASC`)
	if err != nil {
		return nil, fmt.Errorf("query decks: %w", err)
	}
	defer rows.Close()

	decks := []domain.Deck{}
	for rows.Next() {
		d, err := scanDeck(rows)
		if err != nil {
			return nil, err
		}
		c := counts[d.ID]
		d.CardCount, d.DueCount = c.total, c.due
		decks = append(decks, d)
	}
	return decks, rows.Err()
}

// GetDeck returns a single deck with computed cardCount and dueCount.
func (s *Store) GetDeck(id string, now time.Time) (domain.Deck, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.getDeck(id, now)
}

func (s *Store) getDeck(id string, now time.Time) (domain.Deck, error) {
	row := s.db.QueryRow(`
		SELECT id, user_id, title, description, category, difficulty, color, chapters_json, created_at, updated_at
		FROM decks WHERE id = ?`, id)

	d, err := scanDeck(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Deck{}, ErrNotFound
	}
	if err != nil {
		return domain.Deck{}, fmt.Errorf("query deck %s: %w", id, err)
	}

	counts, err := computeDeckCounts(s.db, now, d.ID)
	if err != nil {
		return domain.Deck{}, err
	}
	c := counts[d.ID]
	d.CardCount, d.DueCount = c.total, c.due
	return d, nil
}

// CreateDeck validates and inserts a new deck.
func (s *Store) CreateDeck(deck domain.Deck) (domain.Deck, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	deck = applyDeckDefaults(deck)
	if err := deck.Validate(); err != nil {
		return domain.Deck{}, fmt.Errorf("%w: %v", ErrValidation, err)
	}

	if deck.ID == "" {
		deck.ID = newID("deck")
	}
	now := nowISO()
	if deck.CreatedAt == "" {
		deck.CreatedAt = now
	}
	deck.UpdatedAt = now

	_, err := s.db.Exec(`
		INSERT INTO decks (id, user_id, title, description, category, difficulty, color, chapters_json, deck_order, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(deck_order), -1) + 1 FROM decks), ?, ?)`,
		deck.ID, deck.UserID, deck.Title, deck.Description, string(deck.Category),
		string(deck.Difficulty), deck.Color, encodeStringSlice(deck.Chapters),
		deck.CreatedAt, deck.UpdatedAt,
	)
	if err != nil {
		return domain.Deck{}, fmt.Errorf("insert deck: %w", err)
	}
	return deck, nil
}

// UpdateDeck validates and updates deck metadata without touching its cards.
func (s *Store) UpdateDeck(id string, deck domain.Deck) (domain.Deck, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	deck = applyDeckDefaults(deck)
	if err := deck.Validate(); err != nil {
		return domain.Deck{}, fmt.Errorf("%w: %v", ErrValidation, err)
	}

	res, err := s.db.Exec(`
		UPDATE decks
		SET title = ?, description = ?, category = ?, difficulty = ?, color = ?, chapters_json = ?, updated_at = ?
		WHERE id = ?`,
		deck.Title, deck.Description, string(deck.Category), string(deck.Difficulty),
		deck.Color, encodeStringSlice(deck.Chapters), nowISO(), id,
	)
	if err != nil {
		return domain.Deck{}, fmt.Errorf("update deck %s: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return domain.Deck{}, fmt.Errorf("update deck %s rows affected: %w", id, err)
	}
	if n == 0 {
		return domain.Deck{}, ErrNotFound
	}
	return s.getDeck(id, time.Now())
}

// DeleteDeck removes a deck and cascades to its cards, layers, and review logs.
func (s *Store) DeleteDeck(id string) error {
	s.mu.RLock()
	defer s.mu.RUnlock()

	res, err := s.db.Exec(`DELETE FROM decks WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("delete deck %s: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("delete deck %s rows affected: %w", id, err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// ReorderDecks updates deck_order for the supplied deck IDs inside one transaction.
func (s *Store) ReorderDecks(deckIDs []string) error {
	s.mu.RLock()
	defer s.mu.RUnlock()

	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("begin deck reorder tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	stmt, err := tx.Prepare(`UPDATE decks SET deck_order = ? WHERE id = ?`)
	if err != nil {
		return fmt.Errorf("prepare deck reorder: %w", err)
	}
	defer stmt.Close()

	seen := make(map[string]bool, len(deckIDs))
	order := 0
	for _, id := range deckIDs {
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		if _, err := stmt.Exec(order, id); err != nil {
			return fmt.Errorf("update deck order %s: %w", id, err)
		}
		order++
	}

	rows, err := tx.Query(`SELECT id FROM decks ORDER BY deck_order ASC, created_at ASC, id ASC`)
	if err != nil {
		return fmt.Errorf("list remaining decks for reorder: %w", err)
	}
	var remaining []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			_ = rows.Close()
			return err
		}
		if !seen[id] {
			remaining = append(remaining, id)
		}
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return err
	}
	_ = rows.Close()

	for _, id := range remaining {
		if _, err := stmt.Exec(order, id); err != nil {
			return fmt.Errorf("append remaining deck order %s: %w", id, err)
		}
		order++
	}

	return tx.Commit()
}

func computeDeckCounts(q queryable, now time.Time, deckID string) (map[string]deckCounts, error) {
	query := `SELECT deck_id, total_reviews, next_review_date FROM cards`
	var args []any
	if deckID != "" {
		query += ` WHERE deck_id = ?`
		args = append(args, deckID)
	}
	rows, err := q.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("query card due counts: %w", err)
	}
	defer rows.Close()

	counts := make(map[string]deckCounts)
	for rows.Next() {
		var deckID string
		var totalReviews int
		var nextReview string
		if err := rows.Scan(&deckID, &totalReviews, &nextReview); err != nil {
			return nil, err
		}
		c := counts[deckID]
		c.total++
		if srs.IsCardDue(domain.Flashcard{TotalReviews: totalReviews, NextReviewDate: nextReview}, now) {
			c.due++
		}
		counts[deckID] = c
	}
	return counts, rows.Err()
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanDeck(scanner rowScanner) (domain.Deck, error) {
	var d domain.Deck
	var category, difficulty, chaptersJSON string
	err := scanner.Scan(
		&d.ID, &d.UserID, &d.Title, &d.Description,
		&category, &difficulty, &d.Color, &chaptersJSON,
		&d.CreatedAt, &d.UpdatedAt,
	)
	if err != nil {
		return domain.Deck{}, err
	}
	d.Category = domain.SubjectCategory(category)
	d.Difficulty = domain.Difficulty(difficulty)
	d.Chapters = decodeStringSlice(chaptersJSON)
	return d, nil
}

func applyDeckDefaults(d domain.Deck) domain.Deck {
	if d.UserID == "" {
		d.UserID = "default"
	}
	if d.Color == "" {
		d.Color = "indigo"
	}
	if d.Category == "" {
		d.Category = domain.CategoryGeneralMath
	}
	if d.Difficulty == "" {
		d.Difficulty = domain.DifficultyMedium
	}
	if d.Chapters == nil {
		d.Chapters = []string{}
	}
	return d
}
