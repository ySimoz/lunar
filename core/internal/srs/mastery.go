package srs

import (
	"fmt"
	"math"
	"time"

	"lunar/core/internal/domain"
)

// MasteryStatus describes the learning stage of a card.
type MasteryStatus struct {
	Status string `json:"status"`
	Label  string `json:"label"`
}

// IsCardDue reports whether a card is new or scheduled at or before now.
func IsCardDue(card domain.Flashcard, now time.Time) bool {
	if card.NextReviewDate == "" || card.TotalReviews == 0 {
		return true
	}
	dueAt, err := parseTimestamp(card.NextReviewDate)
	if err != nil {
		return true
	}
	return !dueAt.After(now)
}

// GetCardMasteryStatus classifies a card into new, learning, review, or mastered.
func GetCardMasteryStatus(card domain.Flashcard) MasteryStatus {
	if card.TotalReviews == 0 {
		return MasteryStatus{Status: "new", Label: "New"}
	}
	if card.Repetition < 2 {
		return MasteryStatus{Status: "learning", Label: "Learning"}
	}
	accuracy := float64(card.CorrectCount) / float64(max(1, card.TotalReviews))
	if card.IntervalDays >= 21 && accuracy >= 0.8 {
		return MasteryStatus{Status: "mastered", Label: "Mastered"}
	}
	return MasteryStatus{Status: "review", Label: "Reviewing"}
}

// FormatIntervalDays formats an interval in days for display on rating buttons.
func FormatIntervalDays(days int) string {
	if days <= 0 {
		return "< 1d"
	}
	if days == 1 {
		return "1d"
	}
	if days < 30 {
		return fmt.Sprintf("%dd", days)
	}
	if days < 365 {
		return formatScaledUnit(float64(days)/30.0, "mo")
	}
	return formatScaledUnit(float64(days)/365.0, "y")
}

func formatScaledUnit(value float64, unit string) string {
	rounded := math.Round(value*10) / 10
	if math.Mod(rounded, 1) == 0 {
		return fmt.Sprintf("%.0f%s", rounded, unit)
	}
	return fmt.Sprintf("%.1f%s", rounded, unit)
}

func parseTimestamp(raw string) (time.Time, error) {
	if t, err := time.Parse(time.RFC3339Nano, raw); err == nil {
		return t, nil
	}
	return time.Parse(time.RFC3339, raw)
}
