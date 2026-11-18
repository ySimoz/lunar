package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"lunar/core/internal/domain"
	"lunar/core/internal/srs"
)

type reviewPrevState struct {
	Repetition     int     `json:"repetition"`
	IntervalDays   int     `json:"intervalDays"`
	EaseFactor     float64 `json:"easeFactor"`
	NextReviewDate string  `json:"nextReviewDate"`
	LastReviewed   string  `json:"lastReviewed"`
	TotalReviews   int     `json:"totalReviews"`
	CorrectCount   int     `json:"correctCount"`
	IncorrectCount int     `json:"incorrectCount"`
	UpdatedAt      string  `json:"updatedAt"`
}

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

	prevRaw, err := json.Marshal(reviewPrevState{
		Repetition:     card.Repetition,
		IntervalDays:   card.IntervalDays,
		EaseFactor:     card.EaseFactor,
		NextReviewDate: card.NextReviewDate,
		LastReviewed:   card.LastReviewed,
		TotalReviews:   card.TotalReviews,
		CorrectCount:   card.CorrectCount,
		IncorrectCount: card.IncorrectCount,
		UpdatedAt:      card.UpdatedAt,
	})
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("encode prev state %s: %w", id, err)
	}

	_, err = tx.Exec(
		`INSERT INTO review_logs (card_id, timestamp, rating, interval_days, duration_ms, prev_state) VALUES (?, ?, ?, ?, ?, ?)`,
		id, sm2.Log.Timestamp, sm2.Log.Rating, sm2.Log.IntervalDays, sm2.Log.DurationMs, string(prevRaw),
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

// UndoCardReview atomically restores the card's previous SRS state and deletes the corresponding review_logs row.
func (s *Store) UndoCardReview(id string, reviewLogID *int64) (domain.Flashcard, error) {
	if id == "" {
		return domain.Flashcard{}, fmt.Errorf("%w: card id cannot be empty", ErrValidation)
	}
	if reviewLogID != nil && *reviewLogID <= 0 {
		return domain.Flashcard{}, fmt.Errorf("%w: reviewLogId must be positive", ErrValidation)
	}

	tx, err := s.db.Begin()
	if err != nil {
		return domain.Flashcard{}, err
	}
	defer tx.Rollback()

	var exists int
	err = tx.QueryRow(`SELECT 1 FROM cards WHERE id = ?`, id).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Flashcard{}, ErrNotFound
	}
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("check card %s: %w", id, err)
	}

	var logID int64
	var prevStateRaw string
	err = tx.QueryRow(
		`SELECT id, prev_state FROM review_logs WHERE card_id = ? ORDER BY id DESC LIMIT 1`,
		id,
	).Scan(&logID, &prevStateRaw)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Flashcard{}, fmt.Errorf("%w: card %s has no review to undo", ErrConflict, id)
	}
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("query latest review log %s: %w", id, err)
	}

	if reviewLogID != nil && logID != *reviewLogID {
		return domain.Flashcard{}, fmt.Errorf("%w: review log %d is not the latest review for card %s", ErrConflict, *reviewLogID, id)
	}
	if prevStateRaw == "" {
		return domain.Flashcard{}, fmt.Errorf("%w: review log %d has no previous state snapshot", ErrConflict, logID)
	}

	var prev reviewPrevState
	if err := json.Unmarshal([]byte(prevStateRaw), &prev); err != nil {
		return domain.Flashcard{}, fmt.Errorf("decode prev state for log %d: %w", logID, err)
	}

	if _, err := tx.Exec(`
		UPDATE cards
		SET repetition = ?, interval_days = ?, ease_factor = ?, next_review_date = ?,
		    last_reviewed = ?, total_reviews = ?, correct_count = ?, incorrect_count = ?, updated_at = ?
		WHERE id = ?`,
		prev.Repetition, prev.IntervalDays, prev.EaseFactor, prev.NextReviewDate,
		prev.LastReviewed, prev.TotalReviews, prev.CorrectCount, prev.IncorrectCount,
		prev.UpdatedAt, id,
	); err != nil {
		return domain.Flashcard{}, fmt.Errorf("restore card %s: %w", id, err)
	}

	res, err := tx.Exec(`DELETE FROM review_logs WHERE id = ?`, logID)
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("delete review log %d: %w", logID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return domain.Flashcard{}, fmt.Errorf("delete review log %d rows affected: %w", logID, err)
	}
	if n == 0 {
		return domain.Flashcard{}, fmt.Errorf("%w: review log %d already deleted", ErrConflict, logID)
	}

	restored, err := getCard(tx, id)
	if err != nil {
		return domain.Flashcard{}, err
	}
	if err := tx.Commit(); err != nil {
		return domain.Flashcard{}, err
	}
	return restored, nil
}
