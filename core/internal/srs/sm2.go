// Package srs implements Lunar's modified SM-2 spaced repetition algorithm.
package srs

import (
	"errors"
	"fmt"
	"math"
	"time"

	"lunar/core/internal/domain"
)

const minEaseFactor = 1.3

// SM2Result contains the updated SRS scheduling fields and generated review log.
type SM2Result struct {
	Repetition     int
	IntervalDays   int
	EaseFactor     float64
	NextReviewDate string
	LastReviewed   string
	TotalReviews   int
	CorrectCount   int
	IncorrectCount int
	Log            domain.ReviewLog
}

// IntervalPrediction represents the projected next interval for a rating button.
type IntervalPrediction struct {
	Days  int    `json:"days"`
	Label string `json:"label"`
}

// CalculateSM2 applies the modified SM-2 algorithm using the current local clock.
func CalculateSM2(card domain.Flashcard, quality int, durationMs *int64) (SM2Result, error) {
	return CalculateSM2At(card, quality, durationMs, time.Now())
}

// CalculateSM2At applies the modified SM-2 algorithm relative to the provided timestamp.
func CalculateSM2At(card domain.Flashcard, quality int, durationMs *int64, now time.Time) (SM2Result, error) {
	if durationMs != nil && *durationMs < 0 {
		return SM2Result{}, errors.New("durationMs cannot be negative")
	}
	smQuality, err := mapRatingToSM2(quality)
	if err != nil {
		return SM2Result{}, err
	}

	nextEase := computeNextEase(card.EaseFactor, smQuality)
	rep, interval := computeNextSchedule(card.Repetition, card.IntervalDays, nextEase, quality)

	// Spaced repetition day boundary: cards become due at 4:00 AM local time on the target day.
	target := now.AddDate(0, 0, interval)
	nextDue := time.Date(target.Year(), target.Month(), target.Day(), 4, 0, 0, 0, now.Location()).UTC()
	nowISO := now.UTC().Format(time.RFC3339)

	correct := card.CorrectCount
	incorrect := card.IncorrectCount
	if quality >= 2 {
		correct++
	} else {
		incorrect++
	}

	return SM2Result{
		Repetition:     rep,
		IntervalDays:   interval,
		EaseFactor:     math.Round(nextEase*100) / 100,
		NextReviewDate: nextDue.Format(time.RFC3339),
		LastReviewed:   nowISO,
		TotalReviews:   card.TotalReviews + 1,
		CorrectCount:   correct,
		IncorrectCount: incorrect,
		Log: domain.ReviewLog{
			Timestamp:    nowISO,
			Rating:       quality,
			IntervalDays: interval,
			DurationMs:   durationMs,
		},
	}, nil
}

// PredictInterval previews the interval days and human-readable label for a quality rating (1..4).
func PredictInterval(card domain.Flashcard, quality int) (IntervalPrediction, error) {
	smQuality, err := mapRatingToSM2(quality)
	if err != nil {
		return IntervalPrediction{}, err
	}
	if quality == 1 {
		return IntervalPrediction{Days: 1, Label: "1d"}, nil
	}

	nextEase := computeNextEase(card.EaseFactor, smQuality)
	_, interval := computeNextSchedule(card.Repetition, card.IntervalDays, nextEase, quality)
	return IntervalPrediction{
		Days:  interval,
		Label: FormatIntervalDays(interval),
	}, nil
}

func mapRatingToSM2(quality int) (int, error) {
	switch quality {
	case 1:
		return 1, nil
	case 2:
		return 3, nil
	case 3:
		return 4, nil
	case 4:
		return 5, nil
	default:
		return 0, fmt.Errorf("invalid rating %d: must be between 1 and 4", quality)
	}
}

func computeNextEase(ease float64, smQuality int) float64 {
	if ease <= 0 {
		ease = 2.5
	}
	delta := 0.1 - float64(5-smQuality)*(0.08+float64(5-smQuality)*0.02)
	next := ease + delta
	if next < minEaseFactor {
		return minEaseFactor
	}
	return next
}

func computeNextSchedule(rep, intervalDays int, ease float64, quality int) (int, int) {
	if quality == 1 {
		return 0, 1
	}

	var nextInterval int
	switch {
	case rep == 0:
		if quality == 4 {
			nextInterval = 4
		} else {
			nextInterval = 1
		}
	case rep == 1:
		switch quality {
		case 2:
			nextInterval = 3
		case 4:
			nextInterval = 8
		default:
			nextInterval = 6
		}
	default:
		nextInterval = int(math.Round(float64(intervalDays) * ease))
		if quality == 2 {
			nextInterval = int(math.Round(float64(nextInterval) * 0.8))
		} else if quality == 4 {
			nextInterval = int(math.Round(float64(nextInterval) * 1.3))
		}
		nextInterval = max(1, nextInterval)
	}
	return rep + 1, nextInterval
}
