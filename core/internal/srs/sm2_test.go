package srs_test

import (
	"testing"
	"time"

	"lunar/core/internal/domain"
	"lunar/core/internal/srs"
)

func baseCard() domain.Flashcard {
	return domain.Flashcard{
		ID:           "c1",
		DeckID:       "d1",
		Front:        "Q",
		Back:         "A",
		Difficulty:   domain.DifficultyMedium,
		EaseFactor:   2.5,
		IntervalDays: 1,
	}
}

func TestCalculateSM2_FirstRepetitionRatings(t *testing.T) {
	now := time.Date(2026, 11, 17, 15, 30, 0, 0, time.UTC)

	tests := []struct {
		name           string
		quality        int
		wantRep        int
		wantInterval   int
		wantEase       float64
		wantCorrect    int
		wantIncorrect  int
	}{
		{"again", 1, 0, 1, 1.96, 0, 1},
		{"hard", 2, 1, 1, 2.36, 1, 0},
		{"good", 3, 1, 1, 2.50, 1, 0},
		{"easy", 4, 1, 4, 2.60, 1, 0},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dur := int64(1200)
			res, err := srs.CalculateSM2At(baseCard(), tc.quality, &dur, now)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if res.Repetition != tc.wantRep {
				t.Errorf("repetition = %d, want %d", res.Repetition, tc.wantRep)
			}
			if res.IntervalDays != tc.wantInterval {
				t.Errorf("intervalDays = %d, want %d", res.IntervalDays, tc.wantInterval)
			}
			if res.EaseFactor != tc.wantEase {
				t.Errorf("easeFactor = %v, want %v", res.EaseFactor, tc.wantEase)
			}
			if res.CorrectCount != tc.wantCorrect || res.IncorrectCount != tc.wantIncorrect {
				t.Errorf("counts = (%d, %d), want (%d, %d)", res.CorrectCount, res.IncorrectCount, tc.wantCorrect, tc.wantIncorrect)
			}
			if res.TotalReviews != 1 {
				t.Errorf("totalReviews = %d, want 1", res.TotalReviews)
			}
			if res.Log.DurationMs == nil || *res.Log.DurationMs != 1200 {
				t.Errorf("durationMs = %v, want 1200", res.Log.DurationMs)
			}
		})
	}
}

func TestCalculateSM2_SecondAndHigherRepetitions(t *testing.T) {
	now := time.Date(2026, 11, 17, 10, 0, 0, 0, time.UTC)

	rep1 := baseCard()
	rep1.Repetition = 1
	rep1.TotalReviews = 1
	rep1.CorrectCount = 1

	if res, err := srs.CalculateSM2At(rep1, 2, nil, now); err != nil || res.IntervalDays != 3 {
		t.Fatalf("rep=1 hard: got (%+v, %v), want interval=3", res, err)
	}
	if res, err := srs.CalculateSM2At(rep1, 3, nil, now); err != nil || res.IntervalDays != 6 {
		t.Fatalf("rep=1 good: got (%+v, %v), want interval=6", res, err)
	}
	if res, err := srs.CalculateSM2At(rep1, 4, nil, now); err != nil || res.IntervalDays != 8 {
		t.Fatalf("rep=1 easy: got (%+v, %v), want interval=8", res, err)
	}

	rep2 := baseCard()
	rep2.Repetition = 2
	rep2.IntervalDays = 6
	rep2.EaseFactor = 2.5

	// Good: 6 * 2.5 = 15
	if res, err := srs.CalculateSM2At(rep2, 3, nil, now); err != nil || res.IntervalDays != 15 || res.Repetition != 3 {
		t.Fatalf("rep=2 good: got (%+v, %v), want interval=15 rep=3", res, err)
	}
	// Hard: nextEf = 2.36; round(6 * 2.36) = 14; round(14 * 0.8) = 11
	if res, err := srs.CalculateSM2At(rep2, 2, nil, now); err != nil || res.IntervalDays != 11 {
		t.Fatalf("rep=2 hard: got (%+v, %v), want interval=11", res, err)
	}
	// Easy: nextEf = 2.60; round(6 * 2.60) = 16; round(16 * 1.3) = 21
	if res, err := srs.CalculateSM2At(rep2, 4, nil, now); err != nil || res.IntervalDays != 21 {
		t.Fatalf("rep=2 easy: got (%+v, %v), want interval=21", res, err)
	}
	// Again lapses: rep=0, interval=1
	if res, err := srs.CalculateSM2At(rep2, 1, nil, now); err != nil || res.IntervalDays != 1 || res.Repetition != 0 {
		t.Fatalf("rep=2 again: got (%+v, %v), want interval=1 rep=0", res, err)
	}
}

func TestCalculateSM2_EaseFloorAndInvalidQuality(t *testing.T) {
	now := time.Date(2026, 11, 17, 10, 0, 0, 0, time.UTC)
	card := baseCard()
	card.EaseFactor = 1.35

	res, err := srs.CalculateSM2At(card, 1, nil, now)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.EaseFactor != 1.3 {
		t.Errorf("easeFactor = %v, want floor 1.3", res.EaseFactor)
	}

	for _, bad := range []int{0, 5, -1} {
		if _, err := srs.CalculateSM2At(card, bad, nil, now); err == nil {
			t.Errorf("expected error for invalid quality %d", bad)
		}
	}
}

func TestCalculateSM2_FourAMLocalBoundary(t *testing.T) {
	loc := time.FixedZone("UTC+2", 2*3600)
	// Late night review on Nov 17 local time: 23:30+02:00
	now := time.Date(2026, 11, 17, 23, 30, 0, 0, loc)
	card := baseCard()

	res, err := srs.CalculateSM2At(card, 3, nil, now)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Next day (+1) at 04:00+02:00 == 02:00Z on Nov 18
	want := time.Date(2026, 11, 18, 4, 0, 0, 0, loc).UTC().Format(time.RFC3339)
	if res.NextReviewDate != want {
		t.Errorf("nextReviewDate = %s, want %s", res.NextReviewDate, want)
	}
}

func TestIsCardDue(t *testing.T) {
	now := time.Date(2026, 11, 17, 4, 0, 0, 0, time.UTC)

	newCard := baseCard()
	if !srs.IsCardDue(newCard, now) {
		t.Error("expected new card with 0 reviews to be due")
	}

	dueCard := baseCard()
	dueCard.TotalReviews = 1
	dueCard.NextReviewDate = now.Format(time.RFC3339)
	if !srs.IsCardDue(dueCard, now) {
		t.Error("expected card with nextReviewDate == now to be due")
	}

	futureCard := baseCard()
	futureCard.TotalReviews = 1
	futureCard.NextReviewDate = now.Add(time.Minute).Format(time.RFC3339)
	if srs.IsCardDue(futureCard, now) {
		t.Error("expected card with future nextReviewDate not to be due")
	}
}

func TestGetCardMasteryStatus(t *testing.T) {
	c := baseCard()
	if got := srs.GetCardMasteryStatus(c); got.Status != "new" {
		t.Errorf("got %q, want new", got.Status)
	}

	c.TotalReviews = 1
	c.Repetition = 1
	c.CorrectCount = 1
	if got := srs.GetCardMasteryStatus(c); got.Status != "learning" {
		t.Errorf("got %q, want learning", got.Status)
	}

	c.TotalReviews = 5
	c.Repetition = 2
	c.IntervalDays = 15
	c.CorrectCount = 5
	if got := srs.GetCardMasteryStatus(c); got.Status != "review" {
		t.Errorf("got %q, want review", got.Status)
	}

	// Mastery requires rep >= 2, interval >= 21, accuracy >= 0.8
	c.IntervalDays = 21
	c.CorrectCount = 4 // 4/5 = 0.8
	if got := srs.GetCardMasteryStatus(c); got.Status != "mastered" {
		t.Errorf("got %q, want mastered", got.Status)
	}

	c.CorrectCount = 3 // 3/5 = 0.6 < 0.8
	if got := srs.GetCardMasteryStatus(c); got.Status != "review" {
		t.Errorf("got %q, want review when accuracy < 0.8", got.Status)
	}
}

func TestFormatIntervalDaysAndPredict(t *testing.T) {
	cases := []struct {
		days int
		want string
	}{
		{0, "< 1d"},
		{1, "1d"},
		{14, "14d"},
		{30, "1mo"},
		{45, "1.5mo"},
		{365, "1y"},
		{730, "2y"},
	}
	for _, tc := range cases {
		if got := srs.FormatIntervalDays(tc.days); got != tc.want {
			t.Errorf("FormatIntervalDays(%d) = %q, want %q", tc.days, got, tc.want)
		}
	}

	card := baseCard()
	card.Repetition = 2
	card.IntervalDays = 6
	for q := 1; q <= 4; q++ {
		pred, err := srs.PredictInterval(card, q)
		if err != nil {
			t.Fatalf("PredictInterval(%d) error: %v", q, err)
		}
		res, _ := srs.CalculateSM2At(card, q, nil, time.Now())
		if pred.Days != res.IntervalDays {
			t.Errorf("q=%d: predict days=%d != sm2 days=%d", q, pred.Days, res.IntervalDays)
		}
	}
}

func TestCalculateSM2_MinimumIntervalClampAndNegativeDuration(t *testing.T) {
	now := time.Date(2026, 11, 17, 10, 0, 0, 0, time.UTC)
	card := baseCard()
	card.Repetition = 2
	card.IntervalDays = 0
	card.EaseFactor = 2.5

	for _, q := range []int{2, 3, 4} {
		res, err := srs.CalculateSM2At(card, q, nil, now)
		if err != nil {
			t.Fatalf("q=%d unexpected error: %v", q, err)
		}
		if res.IntervalDays < 1 {
			t.Errorf("q=%d intervalDays = %d, want >= 1", q, res.IntervalDays)
		}
		pred, err := srs.PredictInterval(card, q)
		if err != nil {
			t.Fatalf("PredictInterval(%d) unexpected error: %v", q, err)
		}
		if pred.Days < 1 {
			t.Errorf("q=%d predict.Days = %d, want >= 1", q, pred.Days)
		}
	}

	neg := int64(-10)
	if _, err := srs.CalculateSM2At(card, 3, &neg, now); err == nil {
		t.Fatal("expected error for negative durationMs")
	}
}
