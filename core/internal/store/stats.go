package store

import (
	"database/sql"
	"fmt"
	"time"

	"lunar/core/internal/domain"
	"lunar/core/internal/stats"
)

// GetStats aggregates study analytics, mastery pipeline, streaks, and daily activity.
func (s *Store) GetStats(days int, now time.Time) (stats.Summary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if days < 1 || days > 365 {
		return stats.Summary{}, fmt.Errorf("%w: days must be between 1 and 365", ErrValidation)
	}

	tx, err := s.db.Begin()
	if err != nil {
		return stats.Summary{}, err
	}
	defer tx.Rollback()

	decks, err := queryAllDecks(tx)
	if err != nil {
		return stats.Summary{}, err
	}
	cards, err := queryAllCardsRaw(tx)
	if err != nil {
		return stats.Summary{}, err
	}
	logs, err := queryAllReviewLogs(tx)
	if err != nil {
		return stats.Summary{}, err
	}
	sessions, err := queryAllSessions(tx)
	if err != nil {
		return stats.Summary{}, err
	}

	return stats.Compute(stats.Input{
		Decks:    decks,
		Cards:    cards,
		Logs:     logs,
		Sessions: sessions,
		Days:     days,
		Now:      now,
	}), nil
}

func queryAllDecks(q queryable) ([]domain.Deck, error) {
	rows, err := q.Query(`
		SELECT id, user_id, title, description, category, difficulty, color, chapters_json, created_at, updated_at
		FROM decks
		ORDER BY created_at ASC, id ASC`)
	if err != nil {
		return nil, fmt.Errorf("query decks for stats: %w", err)
	}
	defer rows.Close()

	decks := []domain.Deck{}
	for rows.Next() {
		d, err := scanDeck(rows)
		if err != nil {
			return nil, err
		}
		decks = append(decks, d)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	_ = rows.Close()
	return decks, nil
}

func queryAllCardsRaw(q queryable) ([]domain.Flashcard, error) {
	rows, err := q.Query("SELECT " + cardColumns + " FROM cards ORDER BY card_order ASC, created_at ASC, id ASC")
	if err != nil {
		return nil, fmt.Errorf("query cards for stats: %w", err)
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
	_ = rows.Close()
	return cards, nil
}

func queryAllReviewLogs(q queryable) ([]domain.ReviewLog, error) {
	rows, err := q.Query(`SELECT timestamp, rating, interval_days, duration_ms FROM review_logs ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("query review logs for stats: %w", err)
	}
	defer rows.Close()

	logs := []domain.ReviewLog{}
	for rows.Next() {
		var l domain.ReviewLog
		var duration sql.NullInt64
		if err := rows.Scan(&l.Timestamp, &l.Rating, &l.IntervalDays, &duration); err != nil {
			return nil, err
		}
		if duration.Valid {
			v := duration.Int64
			l.DurationMs = &v
		}
		logs = append(logs, l)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	_ = rows.Close()
	return logs, nil
}

func queryAllSessions(q queryable) ([]domain.StudySessionRecord, error) {
	rows, err := q.Query(`
		SELECT id, user_id, mode, deck_ids_json, deck_titles_json,
		       cards_reviewed, correct_count, incorrect_count, lives_left,
		       duration_seconds, completed_at
		FROM study_sessions
		ORDER BY completed_at DESC, id DESC`)
	if err != nil {
		return nil, fmt.Errorf("query sessions for stats: %w", err)
	}
	defer rows.Close()

	out := []domain.StudySessionRecord{}
	for rows.Next() {
		rec, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	_ = rows.Close()
	return out, nil
}
