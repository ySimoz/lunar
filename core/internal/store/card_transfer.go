package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strings"

	"lunar/core/internal/domain"
)

// TransferCards atomically moves cards to TargetDeckID with TargetTopic, preserving SRS state and review logs.
// If TargetTopic is non-empty and absent from the target deck's chapters, it is appended to chapters_json.
func (s *Store) TransferCards(ctx context.Context, req domain.TransferCardsRequest) (int, error) {
	if err := req.Validate(); err != nil {
		return 0, fmt.Errorf("%w: %v", ErrValidation, err)
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	targetDeckID := strings.TrimSpace(req.TargetDeckID)
	row := tx.QueryRowContext(ctx, `
		SELECT id, user_id, title, description, category, difficulty, color, chapters_json, created_at, updated_at
		FROM decks WHERE id = ?`, targetDeckID)
	targetDeck, err := scanDeck(row)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, fmt.Errorf("%w: target deck %q", ErrNotFound, targetDeckID)
	}
	if err != nil {
		return 0, fmt.Errorf("query target deck %s: %w", targetDeckID, err)
	}

	cardIDs := make([]string, len(req.CardIDs))
	for i, id := range req.CardIDs {
		cardID := strings.TrimSpace(id)
		var exists int
		err := tx.QueryRowContext(ctx, `SELECT 1 FROM cards WHERE id = ?`, cardID).Scan(&exists)
		if errors.Is(err, sql.ErrNoRows) {
			return 0, fmt.Errorf("%w: card %q", ErrNotFound, cardID)
		}
		if err != nil {
			return 0, fmt.Errorf("query card %s: %w", cardID, err)
		}
		cardIDs[i] = cardID
	}

	now := nowISO()
	targetTopic := strings.TrimSpace(req.TargetTopic)
	if targetTopic != "" && !slices.Contains(targetDeck.Chapters, targetTopic) {
		targetDeck.Chapters = append(targetDeck.Chapters, targetTopic)
		if _, err := tx.ExecContext(ctx,
			`UPDATE decks SET chapters_json = ?, updated_at = ? WHERE id = ?`,
			encodeStringSlice(targetDeck.Chapters), now, targetDeck.ID,
		); err != nil {
			return 0, fmt.Errorf("update target deck chapters %s: %w", targetDeck.ID, err)
		}
	}

	var nextOrder int
	if err := tx.QueryRowContext(ctx,
		`SELECT COALESCE(MAX(card_order), -1) + 1 FROM cards WHERE deck_id = ?`,
		targetDeck.ID,
	).Scan(&nextOrder); err != nil {
		return 0, fmt.Errorf("query max card_order for deck %s: %w", targetDeck.ID, err)
	}

	moved := 0
	for i, cardID := range cardIDs {
		res, err := tx.ExecContext(ctx, `
			UPDATE cards
			SET deck_id = ?, topic = ?, card_order = ?, updated_at = ?
			WHERE id = ?`,
			targetDeck.ID, targetTopic, nextOrder+i, now, cardID,
		)
		if err != nil {
			return 0, fmt.Errorf("transfer card %s: %w", cardID, err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return 0, fmt.Errorf("transfer card %s rows affected: %w", cardID, err)
		}
		if n == 0 {
			return 0, fmt.Errorf("%w: card %q", ErrNotFound, cardID)
		}
		moved += int(n)
	}

	if req.TargetIndex != nil {
		if err := reorderDeckChapterOnTransfer(ctx, tx, targetDeck.ID, targetTopic, cardIDs, *req.TargetIndex, now); err != nil {
			return 0, err
		}
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return moved, nil
}

func reorderDeckChapterOnTransfer(
	ctx context.Context,
	tx *sql.Tx,
	deckID string,
	targetTopic string,
	movedIDs []string,
	targetIndex int,
	now string,
) error {
	movedSet := make(map[string]bool, len(movedIDs))
	for _, id := range movedIDs {
		movedSet[id] = true
	}

	rows, err := tx.QueryContext(ctx,
		`SELECT id, topic FROM cards WHERE deck_id = ? ORDER BY card_order ASC, id ASC`,
		deckID,
	)
	if err != nil {
		return fmt.Errorf("list target deck cards %s: %w", deckID, err)
	}
	type cardEntry struct {
		id    string
		topic string
	}
	var others []cardEntry
	var chapterIDs []string
	for rows.Next() {
		var entry cardEntry
		if err := rows.Scan(&entry.id, &entry.topic); err != nil {
			_ = rows.Close()
			return err
		}
		if movedSet[entry.id] {
			continue
		}
		others = append(others, entry)
		if strings.TrimSpace(entry.topic) == targetTopic {
			chapterIDs = append(chapterIDs, entry.id)
		}
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return err
	}
	_ = rows.Close()

	insertAt := min(max(targetIndex, 0), len(chapterIDs))
	updatedChapter := make([]string, 0, len(chapterIDs)+len(movedIDs))
	updatedChapter = append(updatedChapter, chapterIDs[:insertAt]...)
	updatedChapter = append(updatedChapter, movedIDs...)
	updatedChapter = append(updatedChapter, chapterIDs[insertAt:]...)

	finalOrder := make([]string, 0, len(others)+len(movedIDs))
	insertedChapter := false
	for _, entry := range others {
		if strings.TrimSpace(entry.topic) == targetTopic {
			if !insertedChapter {
				finalOrder = append(finalOrder, updatedChapter...)
				insertedChapter = true
			}
			continue
		}
		finalOrder = append(finalOrder, entry.id)
	}
	if !insertedChapter {
		finalOrder = append(finalOrder, updatedChapter...)
	}

	for idx, id := range finalOrder {
		if _, err := tx.ExecContext(ctx,
			`UPDATE cards SET card_order = ?, updated_at = ? WHERE id = ?`,
			idx, now, id,
		); err != nil {
			return fmt.Errorf("resequence transferred card %s: %w", id, err)
		}
	}
	return nil
}
