package store

import (
	"database/sql"
	"errors"
	"fmt"

	"lunar/core/internal/domain"
)

// ListSessions returns completed study sessions ordered newest first.
func (s *Store) ListSessions() ([]domain.StudySessionRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rows, err := s.db.Query(`
		SELECT id, user_id, mode, deck_ids_json, deck_titles_json,
		       cards_reviewed, correct_count, incorrect_count, lives_left,
		       duration_seconds, completed_at
		FROM study_sessions
		ORDER BY completed_at DESC, id DESC`)
	if err != nil {
		return nil, fmt.Errorf("query sessions: %w", err)
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
	return out, rows.Err()
}

// CreateSession validates and persists a completed study session record.
func (s *Store) CreateSession(rec domain.StudySessionRecord) (domain.StudySessionRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if err := rec.Validate(); err != nil {
		return domain.StudySessionRecord{}, fmt.Errorf("%w: %v", ErrValidation, err)
	}
	if rec.ID == "" {
		rec.ID = newID("sess")
	}
	if rec.UserID == "" {
		rec.UserID = "default"
	}
	if rec.CompletedAt == "" {
		rec.CompletedAt = nowISO()
	}
	if rec.DeckIDs == nil {
		rec.DeckIDs = []string{}
	}
	if rec.DeckTitles == nil {
		rec.DeckTitles = []string{}
	}

	_, err := s.db.Exec(`
		INSERT INTO study_sessions (
			id, user_id, mode, deck_ids_json, deck_titles_json,
			cards_reviewed, correct_count, incorrect_count, lives_left,
			duration_seconds, completed_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			user_id = excluded.user_id,
			mode = excluded.mode,
			deck_ids_json = excluded.deck_ids_json,
			deck_titles_json = excluded.deck_titles_json,
			cards_reviewed = excluded.cards_reviewed,
			correct_count = excluded.correct_count,
			incorrect_count = excluded.incorrect_count,
			lives_left = excluded.lives_left,
			duration_seconds = excluded.duration_seconds,
			completed_at = excluded.completed_at`,
		rec.ID, rec.UserID, string(rec.Mode), encodeStringSlice(rec.DeckIDs),
		encodeStringSlice(rec.DeckTitles), rec.CardsReviewed, rec.CorrectCount,
		rec.IncorrectCount, rec.LivesLeft, rec.DurationSeconds, rec.CompletedAt,
	)
	if err != nil {
		return domain.StudySessionRecord{}, fmt.Errorf("insert session: %w", err)
	}
	return rec, nil
}

// GetActiveSession returns the persisted crash-recovery session snapshot or ErrNotFound.
func (s *Store) GetActiveSession() (*domain.ActiveSessionState, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	row := s.db.QueryRow(`
		SELECT session_id, deck_id, deck_ids_json, mode, current_index,
		       card_ids_json, reviewed_card_ids_json, correct_count,
		       incorrect_count, lives_left, started_at
		FROM active_session WHERE id = 1`)

	var st domain.ActiveSessionState
	var deckIDsJSON, cardIDsJSON, reviewedJSON, mode string
	var lives sql.NullInt64
	err := row.Scan(
		&st.SessionID, &st.DeckID, &deckIDsJSON, &mode, &st.CurrentIndex,
		&cardIDsJSON, &reviewedJSON, &st.CorrectCount, &st.IncorrectCount,
		&lives, &st.StartedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("query active session: %w", err)
	}
	st.Mode = domain.StudyMode(mode)
	st.DeckIDs = decodeStringSlice(deckIDsJSON)
	st.CardIDs = decodeStringSlice(cardIDsJSON)
	st.ReviewedCardIDs = decodeStringSlice(reviewedJSON)
	if lives.Valid {
		v := int(lives.Int64)
		st.LivesLeft = &v
	}
	return &st, nil
}

// SaveActiveSession upserts the singleton active session row (id = 1).
func (s *Store) SaveActiveSession(st domain.ActiveSessionState) (domain.ActiveSessionState, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if err := st.Validate(); err != nil {
		return domain.ActiveSessionState{}, fmt.Errorf("%w: %v", ErrValidation, err)
	}
	if st.StartedAt == "" {
		st.StartedAt = nowISO()
	}
	if st.DeckIDs == nil {
		st.DeckIDs = []string{}
	}
	if st.CardIDs == nil {
		st.CardIDs = []string{}
	}
	if st.ReviewedCardIDs == nil {
		st.ReviewedCardIDs = []string{}
	}

	_, err := s.db.Exec(`
		INSERT INTO active_session (
			id, session_id, deck_id, deck_ids_json, mode, current_index,
			card_ids_json, reviewed_card_ids_json, correct_count, incorrect_count,
			lives_left, started_at
		) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			session_id = excluded.session_id,
			deck_id = excluded.deck_id,
			deck_ids_json = excluded.deck_ids_json,
			mode = excluded.mode,
			current_index = excluded.current_index,
			card_ids_json = excluded.card_ids_json,
			reviewed_card_ids_json = excluded.reviewed_card_ids_json,
			correct_count = excluded.correct_count,
			incorrect_count = excluded.incorrect_count,
			lives_left = excluded.lives_left,
			started_at = excluded.started_at`,
		st.SessionID, st.DeckID, encodeStringSlice(st.DeckIDs), string(st.Mode),
		st.CurrentIndex, encodeStringSlice(st.CardIDs), encodeStringSlice(st.ReviewedCardIDs),
		st.CorrectCount, st.IncorrectCount, st.LivesLeft, st.StartedAt,
	)
	if err != nil {
		return domain.ActiveSessionState{}, fmt.Errorf("save active session: %w", err)
	}
	return st, nil
}

// ClearActiveSession removes the singleton active session row.
func (s *Store) ClearActiveSession() error {
	s.mu.RLock()
	defer s.mu.RUnlock()

	_, err := s.db.Exec(`DELETE FROM active_session WHERE id = 1`)
	return err
}

func scanSession(scanner rowScanner) (domain.StudySessionRecord, error) {
	var r domain.StudySessionRecord
	var mode, deckIDsJSON, deckTitlesJSON string
	var lives sql.NullInt64
	err := scanner.Scan(
		&r.ID, &r.UserID, &mode, &deckIDsJSON, &deckTitlesJSON,
		&r.CardsReviewed, &r.CorrectCount, &r.IncorrectCount, &lives,
		&r.DurationSeconds, &r.CompletedAt,
	)
	if err != nil {
		return domain.StudySessionRecord{}, err
	}
	r.Mode = domain.StudyMode(mode)
	r.DeckIDs = decodeStringSlice(deckIDsJSON)
	r.DeckTitles = decodeStringSlice(deckTitlesJSON)
	if lives.Valid {
		v := int(lives.Int64)
		r.LivesLeft = &v
	}
	return r, nil
}
