// Package stats computes spaced-repetition analytics, mastery pipelines, and daily streaks.
package stats

import (
	"math"
	"sort"
	"time"

	"lunar/core/internal/domain"
	"lunar/core/internal/srs"
)

// MasteryPipeline summarizes card counts across SM-2 learning stages.
type MasteryPipeline struct {
	NewCount        int `json:"newCount"`
	LearningCount   int `json:"learningCount"`
	ReviewCount     int `json:"reviewCount"`
	MasteredCount   int `json:"masteredCount"`
	MasteredPercent int `json:"masteredPercent"`
}

// DeckBreakdown summarizes card mastery, due count, and average ease for one deck.
type DeckBreakdown struct {
	DeckID          string  `json:"deckId"`
	Title           string  `json:"title"`
	TotalCards      int     `json:"totalCards"`
	DueCards        int     `json:"dueCards"`
	MasteredCards   int     `json:"masteredCards"`
	MasteredPercent int     `json:"masteredPercent"`
	AverageEase     float64 `json:"averageEase"`
}

// DailyActivity holds one local calendar day's review and study-time totals.
type DailyActivity struct {
	Date         string `json:"date"`
	Reviews      int    `json:"reviews"`
	Correct      int    `json:"correct"`
	StudySeconds int    `json:"studySeconds"`
}

// Summary contains global KPIs, mastery breakdown, per-deck stats, and daily trends.
type Summary struct {
	TotalCards        int             `json:"totalCards"`
	DueCards          int             `json:"dueCards"`
	TotalReviews      int             `json:"totalReviews"`
	TotalCorrect      int             `json:"totalCorrect"`
	RetentionRate     int             `json:"retentionRate"`
	TotalStudySeconds int             `json:"totalStudySeconds"`
	CurrentStreakDays int             `json:"currentStreakDays"`
	LongestStreakDays int             `json:"longestStreakDays"`
	MasteryPipeline   MasteryPipeline `json:"masteryPipeline"`
	DeckBreakdown     []DeckBreakdown `json:"deckBreakdown"`
	DailyActivity     []DailyActivity `json:"dailyActivity"`
}

// Input provides the raw records required to compute a Summary.
type Input struct {
	Decks    []domain.Deck
	Cards    []domain.Flashcard
	Logs     []domain.ReviewLog
	Sessions []domain.StudySessionRecord
	Days     int
	Now      time.Time
}

type deckAgg struct {
	total    int
	due      int
	mastered int
	sumEase  float64
}

type dayKey struct {
	year  int
	month time.Month
	day   int
}

func toDayKey(t time.Time) dayKey {
	y, m, d := t.Date()
	return dayKey{year: y, month: m, day: d}
}

func (k dayKey) format() string {
	return time.Date(k.year, k.month, k.day, 0, 0, 0, 0, time.UTC).Format("2006-01-02")
}

func (k dayKey) addDays(n int) dayKey {
	t := time.Date(k.year, k.month, k.day, 0, 0, 0, 0, time.UTC).AddDate(0, 0, n)
	return toDayKey(t)
}

// Compute calculates global KPIs, mastery pipeline, per-deck breakdown, streaks, and daily trends.
func Compute(in Input) Summary {
	days := in.Days
	if days <= 0 {
		days = 30
	}
	now := in.Now
	if now.IsZero() {
		now = time.Now()
	}
	loc := now.Location()

	var pipeline MasteryPipeline
	var totalReviews, totalCorrect, dueCards int
	perDeck := make(map[string]*deckAgg, len(in.Decks))

	for _, c := range in.Cards {
		totalReviews += c.TotalReviews
		totalCorrect += c.CorrectCount

		isDue := srs.IsCardDue(c, now)
		if isDue {
			dueCards++
		}

		stage := srs.GetCardMasteryStatus(c).Status
		switch stage {
		case "new":
			pipeline.NewCount++
		case "learning":
			pipeline.LearningCount++
		case "mastered":
			pipeline.MasteredCount++
		default:
			pipeline.ReviewCount++
		}

		agg, ok := perDeck[c.DeckID]
		if !ok {
			agg = &deckAgg{}
			perDeck[c.DeckID] = agg
		}
		agg.total++
		if isDue {
			agg.due++
		}
		if stage == "mastered" {
			agg.mastered++
		}
		ease := c.EaseFactor
		if ease <= 0 {
			ease = 2.5
		}
		agg.sumEase += ease
	}

	totalCards := len(in.Cards)
	if totalCards > 0 {
		pipeline.MasteredPercent = int(math.Round(float64(pipeline.MasteredCount) / float64(totalCards) * 100))
	}

	retentionRate := 0
	if totalReviews > 0 {
		retentionRate = int(math.Round(float64(totalCorrect) / float64(totalReviews) * 100))
	}

	breakdown := make([]DeckBreakdown, 0, len(in.Decks))
	for _, d := range in.Decks {
		agg := perDeck[d.ID]
		if agg == nil {
			breakdown = append(breakdown, DeckBreakdown{
				DeckID: d.ID,
				Title:  d.Title,
			})
			continue
		}
		masteredPct := 0
		avgEase := 0.0
		if agg.total > 0 {
			masteredPct = int(math.Round(float64(agg.mastered) / float64(agg.total) * 100))
			avgEase = math.Round((agg.sumEase/float64(agg.total))*100) / 100
		}
		breakdown = append(breakdown, DeckBreakdown{
			DeckID:          d.ID,
			Title:           d.Title,
			TotalCards:      agg.total,
			DueCards:        agg.due,
			MasteredCards:   agg.mastered,
			MasteredPercent: masteredPct,
			AverageEase:     avgEase,
		})
	}

	activeDays := make(map[dayKey]struct{})
	dailyReviews := make(map[dayKey]int)
	dailyCorrect := make(map[dayKey]int)
	dailyStudySec := make(map[dayKey]int)

	for _, log := range in.Logs {
		ts, err := parseTimestamp(log.Timestamp)
		if err != nil {
			continue
		}
		dk := toDayKey(ts.In(loc))
		activeDays[dk] = struct{}{}
		dailyReviews[dk]++
		if log.Rating >= 2 {
			dailyCorrect[dk]++
		}
	}

	totalStudySeconds := 0
	for _, sess := range in.Sessions {
		totalStudySeconds += sess.DurationSeconds
		ts, err := parseTimestamp(sess.CompletedAt)
		if err != nil {
			continue
		}
		dk := toDayKey(ts.In(loc))
		activeDays[dk] = struct{}{}
		dailyStudySec[dk] += sess.DurationSeconds
	}

	today := toDayKey(now.In(loc))
	currentStreak, longestStreak := computeStreaks(activeDays, today)

	activity := make([]DailyActivity, 0, days)
	start := today.addDays(-(days - 1))
	for i := 0; i < days; i++ {
		dk := start.addDays(i)
		activity = append(activity, DailyActivity{
			Date:         dk.format(),
			Reviews:      dailyReviews[dk],
			Correct:      dailyCorrect[dk],
			StudySeconds: dailyStudySec[dk],
		})
	}

	return Summary{
		TotalCards:        totalCards,
		DueCards:          dueCards,
		TotalReviews:      totalReviews,
		TotalCorrect:      totalCorrect,
		RetentionRate:     retentionRate,
		TotalStudySeconds: totalStudySeconds,
		CurrentStreakDays: currentStreak,
		LongestStreakDays: longestStreak,
		MasteryPipeline:   pipeline,
		DeckBreakdown:     breakdown,
		DailyActivity:     activity,
	}
}

func computeStreaks(active map[dayKey]struct{}, today dayKey) (int, int) {
	if len(active) == 0 {
		return 0, 0
	}

	sorted := make([]dayKey, 0, len(active))
	for dk := range active {
		sorted = append(sorted, dk)
	}
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].year != sorted[j].year {
			return sorted[i].year < sorted[j].year
		}
		if sorted[i].month != sorted[j].month {
			return sorted[i].month < sorted[j].month
		}
		return sorted[i].day < sorted[j].day
	})

	longest := 1
	run := 1
	for i := 1; i < len(sorted); i++ {
		if sorted[i-1].addDays(1) == sorted[i] {
			run++
			if run > longest {
				longest = run
			}
		} else {
			run = 1
		}
	}

	// Current streak stays alive if today is active or yesterday was active.
	cursor := today
	if _, ok := active[cursor]; !ok {
		yesterday := today.addDays(-1)
		if _, ok := active[yesterday]; !ok {
			return 0, longest
		}
		cursor = yesterday
	}

	current := 0
	for {
		if _, ok := active[cursor]; !ok {
			break
		}
		current++
		cursor = cursor.addDays(-1)
	}

	return current, longest
}

func parseTimestamp(raw string) (time.Time, error) {
	if t, err := time.Parse(time.RFC3339Nano, raw); err == nil {
		return t, nil
	}
	return time.Parse(time.RFC3339, raw)
}
