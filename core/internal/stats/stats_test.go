package stats_test

import (
	"testing"
	"time"

	"lunar/core/internal/domain"
	"lunar/core/internal/stats"
)

func TestCompute_EmptyInput(t *testing.T) {
	now := time.Date(2026, 11, 17, 15, 0, 0, 0, time.UTC)
	sum := stats.Compute(stats.Input{
		Days: 30,
		Now:  now,
	})

	if sum.TotalCards != 0 || sum.DueCards != 0 || sum.RetentionRate != 0 || sum.CurrentStreakDays != 0 || sum.LongestStreakDays != 0 {
		t.Fatalf("expected zero KPIs on empty input, got %+v", sum)
	}
	if sum.DeckBreakdown == nil || len(sum.DeckBreakdown) != 0 {
		t.Fatalf("DeckBreakdown = %#v, want non-nil empty slice", sum.DeckBreakdown)
	}
	if len(sum.DailyActivity) != 30 {
		t.Fatalf("len(DailyActivity) = %d, want 30", len(sum.DailyActivity))
	}
	if sum.DailyActivity[0].Date != "2026-10-19" || sum.DailyActivity[29].Date != "2026-11-17" {
		t.Fatalf("unexpected date range: %s .. %s", sum.DailyActivity[0].Date, sum.DailyActivity[29].Date)
	}
}

func TestCompute_MasteryBucketsAndDeckBreakdown(t *testing.T) {
	now := time.Date(2026, 11, 17, 12, 0, 0, 0, time.UTC)
	future := now.Add(48 * time.Hour).Format(time.RFC3339)
	past := now.Add(-2 * time.Hour).Format(time.RFC3339)

	decks := []domain.Deck{
		{ID: "d1", Title: "Analysis"},
		{ID: "d2", Title: "Empty Deck"},
	}
	cards := []domain.Flashcard{
		// New (due)
		{ID: "c1", DeckID: "d1", TotalReviews: 0, EaseFactor: 2.5},
		// Learning (due)
		{ID: "c2", DeckID: "d1", TotalReviews: 2, Repetition: 1, CorrectCount: 1, EaseFactor: 2.2, NextReviewDate: past},
		// Review (not due)
		{ID: "c3", DeckID: "d1", TotalReviews: 4, Repetition: 2, IntervalDays: 10, CorrectCount: 4, EaseFactor: 2.5, NextReviewDate: future},
		// Mastered (not due: rep>=2, interval>=21, acc>=0.8)
		{ID: "c4", DeckID: "d1", TotalReviews: 5, Repetition: 3, IntervalDays: 25, CorrectCount: 4, EaseFactor: 2.8, NextReviewDate: future},
	}

	sum := stats.Compute(stats.Input{
		Decks: decks,
		Cards: cards,
		Days:  7,
		Now:   now,
	})

	if sum.TotalCards != 4 || sum.DueCards != 2 {
		t.Fatalf("TotalCards=%d DueCards=%d, want 4/2", sum.TotalCards, sum.DueCards)
	}
	if sum.TotalReviews != 11 || sum.TotalCorrect != 9 || sum.RetentionRate != 82 {
		t.Fatalf("reviews=%d correct=%d retention=%d, want 11/9/82", sum.TotalReviews, sum.TotalCorrect, sum.RetentionRate)
	}
	p := sum.MasteryPipeline
	if p.NewCount != 1 || p.LearningCount != 1 || p.ReviewCount != 1 || p.MasteredCount != 1 || p.MasteredPercent != 25 {
		t.Fatalf("unexpected MasteryPipeline: %+v", p)
	}

	if len(sum.DeckBreakdown) != 2 {
		t.Fatalf("len(DeckBreakdown) = %d, want 2", len(sum.DeckBreakdown))
	}
	d1 := sum.DeckBreakdown[0]
	if d1.TotalCards != 4 || d1.DueCards != 2 || d1.MasteredCards != 1 || d1.MasteredPercent != 25 || d1.AverageEase != 2.5 {
		t.Fatalf("unexpected d1 breakdown: %+v", d1)
	}
	d2 := sum.DeckBreakdown[1]
	if d2.TotalCards != 0 || d2.AverageEase != 0 {
		t.Fatalf("unexpected empty deck breakdown: %+v", d2)
	}
}

func TestCompute_StreaksAndDailyActivity(t *testing.T) {
	loc := time.FixedZone("UTC+2", 2*3600)
	// Today is 2026-11-17 local time
	now := time.Date(2026, 11, 17, 10, 0, 0, 0, loc)

	// Historical longest streak: Nov 1, 2, 3, 4 (4 days)
	// Broken on Nov 5..14
	// Current streak: Nov 15, 16 (2 days; today Nov 17 has no logs yet -> still alive at 2)
	logs := []domain.ReviewLog{
		{Timestamp: time.Date(2026, 11, 1, 23, 0, 0, 0, loc).UTC().Format(time.RFC3339), Rating: 3},
		{Timestamp: time.Date(2026, 11, 2, 9, 0, 0, 0, loc).UTC().Format(time.RFC3339), Rating: 1},
		{Timestamp: time.Date(2026, 11, 3, 12, 0, 0, 0, loc).UTC().Format(time.RFC3339), Rating: 4},
		{Timestamp: time.Date(2026, 11, 15, 14, 0, 0, 0, loc).UTC().Format(time.RFC3339), Rating: 3},
		{Timestamp: time.Date(2026, 11, 16, 18, 0, 0, 0, loc).UTC().Format(time.RFC3339), Rating: 2},
		{Timestamp: time.Date(2026, 11, 16, 19, 0, 0, 0, loc).UTC().Format(time.RFC3339), Rating: 1},
	}
	sessions := []domain.StudySessionRecord{
		{DurationSeconds: 120, CompletedAt: time.Date(2026, 11, 4, 8, 0, 0, 0, loc).UTC().Format(time.RFC3339)},
		{DurationSeconds: 300, CompletedAt: time.Date(2026, 11, 16, 20, 0, 0, 0, loc).UTC().Format(time.RFC3339)},
	}

	sum := stats.Compute(stats.Input{
		Logs:     logs,
		Sessions: sessions,
		Days:     14,
		Now:      now,
	})

	if sum.LongestStreakDays != 4 {
		t.Fatalf("LongestStreakDays = %d, want 4", sum.LongestStreakDays)
	}
	if sum.CurrentStreakDays != 2 {
		t.Fatalf("CurrentStreakDays = %d, want 2 (yesterday active)", sum.CurrentStreakDays)
	}
	if sum.TotalStudySeconds != 420 {
		t.Fatalf("TotalStudySeconds = %d, want 420", sum.TotalStudySeconds)
	}
	if len(sum.DailyActivity) != 14 {
		t.Fatalf("len(DailyActivity) = %d, want 14", len(sum.DailyActivity))
	}

	// Nov 16 is index 12 (14 days: Nov 4..Nov 17 -> index 12 is 2026-11-16, index 13 is 2026-11-17)
	nov16 := sum.DailyActivity[12]
	if nov16.Date != "2026-11-16" || nov16.Reviews != 2 || nov16.Correct != 1 || nov16.StudySeconds != 300 {
		t.Fatalf("unexpected Nov 16 activity: %+v", nov16)
	}

	// If neither today nor yesterday has activity, current streak breaks to 0.
	later := now.AddDate(0, 0, 2) // Nov 19
	sumBroken := stats.Compute(stats.Input{
		Logs:     logs,
		Sessions: sessions,
		Days:     14,
		Now:      later,
	})
	if sumBroken.CurrentStreakDays != 0 || sumBroken.LongestStreakDays != 4 {
		t.Fatalf("broken streak = (%d, %d), want (0, 4)", sumBroken.CurrentStreakDays, sumBroken.LongestStreakDays)
	}
}
