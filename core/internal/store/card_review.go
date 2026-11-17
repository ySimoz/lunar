package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"lunar/core/internal/domain"
	"lunar/core/internal/srs"
)

// ReorderCards updates card_order for each card ID within deckID.
func (s *Store) ReorderCards(deckID string, cardIDs []string) error {
	if len(cardIDs) == 0 {
		return fmt.Errorf("%w: cardIds cannot be empty", ErrValidation)
	}
	seen := make(map[string]struct{}, len(cardIDs))
	for _, cardID := range cardIDs {
		if cardID == "" {
			return fmt.Errorf("%w: cardId cannot be empty", ErrValidation)
		}
		if _, dup := seen[cardID]; dup {
			return fmt.Errorf("%w: duplicate cardId %q", ErrValidation, cardID)
		}
		seen[cardID] = struct{}{}
	}

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if err := requireDeckExists(tx, deckID); err != nil {
		return err
	}

	now := nowISO()
	for idx, cardID := range cardIDs {
		res, err := tx.Exec(
			`UPDATE cards SET card_order = ?, updated_at = ? WHERE id = ? AND deck_id = ?`,
			idx, now, cardID, deckID,
		)
		if err != nil {
			return fmt.Errorf("reorder card %s: %w", cardID, err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return fmt.Errorf("reorder card %s rows affected: %w", cardID, err)
		}
		if n == 0 {
			return fmt.Errorf("%w: card %q does not belong to deck %q", ErrValidation, cardID, deckID)
		}
	}
	return tx.Commit()
}

// ReviewCard atomically runs SM-2, updates SRS fields, and appends a review_logs entry.
func (s *Store) ReviewCard(id string, rating int, durationMs *int64, now time.Time) (domain.Flashcard, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return domain.Flashcard{}, err
	}
	defer tx.Rollback()

	card, err := scanCard(tx.QueryRow("SELECT "+cardColumns+" FROM cards WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Flashcard{}, ErrNotFound
	}
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("query card %s: %w", id, err)
	}

	sm2, err := srs.CalculateSM2At(card, rating, durationMs, now)
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("%w: %v", ErrValidation, err)
	}

	res, err := tx.Exec(`
		UPDATE cards
		SET repetition = ?, interval_days = ?, ease_factor = ?, next_review_date = ?,
		    last_reviewed = ?, total_reviews = ?, correct_count = ?, incorrect_count = ?, updated_at = ?
		WHERE id = ?`,
		sm2.Repetition, sm2.IntervalDays, sm2.EaseFactor, sm2.NextReviewDate,
		sm2.LastReviewed, sm2.TotalReviews, sm2.CorrectCount, sm2.IncorrectCount,
		now.UTC().Format(time.RFC3339), id,
	)
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("update card review %s: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("update card review %s rows affected: %w", id, err)
	}
	if n == 0 {
		return domain.Flashcard{}, ErrNotFound
	}

	_, err = tx.Exec(
		`INSERT INTO review_logs (card_id, timestamp, rating, interval_days, duration_ms) VALUES (?, ?, ?, ?, ?)`,
		id, sm2.Log.Timestamp, sm2.Log.Rating, sm2.Log.IntervalDays, sm2.Log.DurationMs,
	)
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("insert review log %s: %w", id, err)
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
