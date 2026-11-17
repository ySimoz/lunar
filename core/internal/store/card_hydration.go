package store

import (
	"database/sql"
	"fmt"

	"lunar/core/internal/domain"
)

func scanCard(scanner rowScanner) (domain.Flashcard, error) {
	var c domain.Flashcard
	var cardType, difficulty, tagsJSON string
	err := scanner.Scan(
		&c.ID, &c.DeckID, &c.UserID, &c.Topic, &c.Order, &cardType,
		&c.Front, &c.Back, &c.Explanation, &difficulty, &tagsJSON,
		&c.Repetition, &c.IntervalDays, &c.EaseFactor, &c.NextReviewDate,
		&c.LastReviewed, &c.TotalReviews, &c.CorrectCount, &c.IncorrectCount,
		&c.CreatedAt, &c.UpdatedAt,
	)
	if err != nil {
		return domain.Flashcard{}, err
	}
	c.CardType = domain.CardType(cardType)
	c.Difficulty = domain.Difficulty(difficulty)
	c.Tags = decodeStringSlice(tagsJSON)
	c.Layers = []domain.CardLayer{}
	c.History = []domain.ReviewLog{}
	return c, nil
}

type queryable interface {
	Query(query string, args ...any) (*sql.Rows, error)
}

type queryRunner interface {
	queryable
	QueryRow(query string, args ...any) *sql.Row
}

func hydrateCardRelations(q queryable, c *domain.Flashcard) error {
	layers, err := loadCardLayers(q, c.ID)
	if err != nil {
		return err
	}
	history, err := loadCardHistory(q, c.ID)
	if err != nil {
		return err
	}
	c.Layers = layers
	c.History = history
	return nil
}

func loadCardLayers(q queryable, cardID string) ([]domain.CardLayer, error) {
	rows, err := q.Query(`
		SELECT id, title, content
		FROM card_layers
		WHERE card_id = ?
		ORDER BY position ASC, id ASC`, cardID)
	if err != nil {
		return nil, fmt.Errorf("query layers for card %s: %w", cardID, err)
	}
	defer rows.Close()

	layers := []domain.CardLayer{}
	for rows.Next() {
		var l domain.CardLayer
		if err := rows.Scan(&l.ID, &l.Title, &l.Content); err != nil {
			return nil, err
		}
		layers = append(layers, l)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	_ = rows.Close()
	return layers, nil
}

func loadCardHistory(q queryable, cardID string) ([]domain.ReviewLog, error) {
	rows, err := q.Query(`
		SELECT timestamp, rating, interval_days, duration_ms
		FROM review_logs
		WHERE card_id = ?
		ORDER BY id ASC`, cardID)
	if err != nil {
		return nil, fmt.Errorf("query review logs for card %s: %w", cardID, err)
	}
	defer rows.Close()

	logs := []domain.ReviewLog{}
	for rows.Next() {
		var log domain.ReviewLog
		var duration sql.NullInt64
		if err := rows.Scan(&log.Timestamp, &log.Rating, &log.IntervalDays, &duration); err != nil {
			return nil, err
		}
		if duration.Valid {
			v := duration.Int64
			log.DurationMs = &v
		}
		logs = append(logs, log)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	_ = rows.Close()
	return logs, nil
}

func replaceCardLayers(tx *sql.Tx, cardID string, layers []domain.CardLayer) ([]domain.CardLayer, error) {
	if _, err := tx.Exec(`DELETE FROM card_layers WHERE card_id = ?`, cardID); err != nil {
		return nil, fmt.Errorf("clear layers for card %s: %w", cardID, err)
	}
	saved := make([]domain.CardLayer, 0, len(layers))
	for idx, l := range layers {
		if l.ID == "" {
			l.ID = newID("layer")
		}
		if _, err := tx.Exec(
			`INSERT INTO card_layers (id, card_id, position, title, content) VALUES (?, ?, ?, ?, ?)`,
			l.ID, cardID, idx, l.Title, l.Content,
		); err != nil {
			return nil, fmt.Errorf("insert layer %d for card %s: %w", idx, cardID, err)
		}
		saved = append(saved, l)
	}
	return saved, nil
}

func applyCardDefaults(c domain.Flashcard) domain.Flashcard {
	if c.UserID == "" {
		c.UserID = "default"
	}
	if c.Difficulty == "" {
		c.Difficulty = domain.DifficultyMedium
	}
	if c.EaseFactor == 0 {
		c.EaseFactor = 2.5
	}
	if c.IntervalDays == 0 && c.TotalReviews == 0 {
		c.IntervalDays = 1
	}
	if c.Tags == nil {
		c.Tags = []string{}
	}
	if c.Layers == nil {
		c.Layers = []domain.CardLayer{}
	}
	if c.History == nil {
		c.History = []domain.ReviewLog{}
	}
	return c
}

func insertCardRow(tx *sql.Tx, c domain.Flashcard) error {
	_, err := tx.Exec(`
		INSERT INTO cards (
			id, deck_id, user_id, topic, card_order, card_type, front, back,
			explanation, difficulty, tags_json, repetition, interval_days, ease_factor,
			next_review_date, last_reviewed, total_reviews, correct_count, incorrect_count,
			created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		c.ID, c.DeckID, c.UserID, c.Topic, c.Order, string(c.CardType), c.Front, c.Back,
		c.Explanation, string(c.Difficulty), encodeStringSlice(c.Tags),
		c.Repetition, c.IntervalDays, c.EaseFactor, c.NextReviewDate, c.LastReviewed,
		c.TotalReviews, c.CorrectCount, c.IncorrectCount, c.CreatedAt, c.UpdatedAt,
	)
	return err
}
