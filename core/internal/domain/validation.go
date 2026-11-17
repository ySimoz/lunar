package domain

import (
	"errors"
	"strings"
)

// IsValid reports whether d is a recognized Difficulty value.
func (d Difficulty) IsValid() bool {
	switch d {
	case DifficultyEasy, DifficultyMedium, DifficultyHard, DifficultyMaster:
		return true
	default:
		return false
	}
}

// IsValid reports whether t is a recognized CardType value.
func (t CardType) IsValid() bool {
	switch t {
	case CardTypeDefinition, CardTypeTheorem, CardTypeExample:
		return true
	default:
		return false
	}
}

// IsValid reports whether c is one of the 11 recognized SubjectCategory values.
func (c SubjectCategory) IsValid() bool {
	switch c {
	case CategoryCalculus, CategoryLinearAlgebra, CategoryRealAnalysis,
		CategoryComplexAnalysis, CategoryAbstractAlgebra, CategoryTopology,
		CategoryProbabilityStatistics, CategoryDiscreteMath,
		CategoryDifferentialEquations, CategoryGeometry, CategoryGeneralMath:
		return true
	default:
		return false
	}
}

// IsValid reports whether m is a recognized StudyMode value.
func (m StudyMode) IsValid() bool {
	switch m {
	case StudyModeStandard, StudyModeMixed, StudyModeSurvival:
		return true
	default:
		return false
	}
}

// Validate checks required fields and enum invariants for a Deck.
func (d Deck) Validate() error {
	if strings.TrimSpace(d.Title) == "" {
		return errors.New("deck title is required")
	}
	if !d.Category.IsValid() {
		return errors.New("invalid deck category")
	}
	if !d.Difficulty.IsValid() {
		return errors.New("invalid deck difficulty")
	}
	return nil
}

// Validate checks required fields and invariants for a Flashcard.
func (f Flashcard) Validate() error {
	if strings.TrimSpace(f.DeckID) == "" {
		return errors.New("flashcard deckId is required")
	}
	if strings.TrimSpace(f.Front) == "" {
		return errors.New("flashcard front is required")
	}
	if strings.TrimSpace(f.Back) == "" {
		return errors.New("flashcard back is required")
	}
	if !f.Difficulty.IsValid() {
		return errors.New("invalid flashcard difficulty")
	}
	if f.CardType != "" && !f.CardType.IsValid() {
		return errors.New("invalid flashcard cardType")
	}
	seenLayerIDs := make(map[string]struct{}, len(f.Layers))
	for _, layer := range f.Layers {
		if layer.ID == "" {
			continue
		}
		if _, exists := seenLayerIDs[layer.ID]; exists {
			return errors.New("flashcard layer ids must be unique")
		}
		seenLayerIDs[layer.ID] = struct{}{}
	}
	return validateFlashcardSRS(f)
}

func validateFlashcardSRS(f Flashcard) error {
	if f.Repetition < 0 || f.IntervalDays < 0 || f.TotalReviews < 0 ||
		f.CorrectCount < 0 || f.IncorrectCount < 0 {
		return errors.New("flashcard review counters cannot be negative")
	}
	if f.EaseFactor != 0 && f.EaseFactor < 1.3 {
		return errors.New("flashcard easeFactor cannot be below 1.3")
	}
	return nil
}

// Validate checks required fields and invariants for a StudySessionRecord.
func (s StudySessionRecord) Validate() error {
	if !s.Mode.IsValid() {
		return errors.New("invalid study mode")
	}
	if s.CardsReviewed < 0 || s.CorrectCount < 0 || s.IncorrectCount < 0 || s.DurationSeconds < 0 {
		return errors.New("session counters and duration cannot be negative")
	}
	if s.LivesLeft != nil && *s.LivesLeft < 0 {
		return errors.New("livesLeft cannot be negative")
	}
	return nil
}

// Validate checks required fields and invariants for an ActiveSessionState.
func (a ActiveSessionState) Validate() error {
	if strings.TrimSpace(a.SessionID) == "" {
		return errors.New("sessionId is required")
	}
	if !a.Mode.IsValid() {
		return errors.New("invalid active session mode")
	}
	if a.CurrentIndex < 0 || a.CorrectCount < 0 || a.IncorrectCount < 0 {
		return errors.New("active session counters cannot be negative")
	}
	if a.LivesLeft != nil && *a.LivesLeft < 0 {
		return errors.New("livesLeft cannot be negative")
	}
	return nil
}

// Validate checks allowed values for UserPreferences.
func (p UserPreferences) Validate() error {
	switch p.FontFamily {
	case "serif", "sans", "mono", "pixel":
	default:
		return errors.New("invalid fontFamily")
	}
	switch p.FontSize {
	case "sm", "base", "lg", "xl":
	default:
		return errors.New("invalid fontSize")
	}
	if p.RetroUIFont != "" {
		switch p.RetroUIFont {
		case "share-tech", "space-mono", "pixelify":
		default:
			return errors.New("invalid retroUIFont")
		}
	}
	switch p.Theme {
	case "lunar-emerald", "lunar-purple", "lunar-solaris", "lunar-bordeaux",
		"lunar-nordic", "lunar-obsidian", "lunar-eclipse", "lunar-chalkboard",
		"lunar-daylight", "dark", "academic-light", "midnight-chalkboard":
	default:
		return errors.New("invalid theme")
	}
	if p.ColorMode != "" && p.ColorMode != "dark" && p.ColorMode != "light" {
		return errors.New("invalid colorMode")
	}
	if p.DefaultLives < 0 {
		return errors.New("defaultLives cannot be negative")
	}
	if p.ClockStyle != "" {
		switch p.ClockStyle {
		case "circular", "analog", "digital", "minimal", "arcade":
		default:
			return errors.New("invalid clockStyle")
		}
	}
	return nil
}

// Validate checks required fields and uniqueness invariants for a TransferCardsRequest.
func (r TransferCardsRequest) Validate() error {
	if strings.TrimSpace(r.TargetDeckID) == "" {
		return errors.New("targetDeckId is required")
	}
	if len(r.CardIDs) == 0 {
		return errors.New("cardIds cannot be empty")
	}
	seen := make(map[string]struct{}, len(r.CardIDs))
	for _, id := range r.CardIDs {
		trimmed := strings.TrimSpace(id)
		if trimmed == "" {
			return errors.New("cardId cannot be empty")
		}
		if _, dup := seen[trimmed]; dup {
			return errors.New("cardIds must be unique")
		}
		seen[trimmed] = struct{}{}
	}
	if r.TargetIndex != nil && *r.TargetIndex < 0 {
		return errors.New("targetIndex cannot be negative")
	}
	return nil
}
