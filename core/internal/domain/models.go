// Package domain defines core Lunar entities, enums, defaults, and validation.
package domain

// Difficulty represents the complexity tier of a deck or flashcard.
type Difficulty string

const (
	DifficultyEasy   Difficulty = "easy"
	DifficultyMedium Difficulty = "medium"
	DifficultyHard   Difficulty = "hard"
	DifficultyMaster Difficulty = "master"
)

// CardType classifies the pedagogical role of a mathematical flashcard.
type CardType string

const (
	CardTypeDefinition CardType = "definition"
	CardTypeTheorem    CardType = "theorem"
	CardTypeExample    CardType = "example"
)

// SubjectCategory identifies one of the 11 supported mathematics disciplines.
type SubjectCategory string

const (
	CategoryCalculus              SubjectCategory = "Calculus"
	CategoryLinearAlgebra         SubjectCategory = "Linear Algebra"
	CategoryRealAnalysis          SubjectCategory = "Real Analysis"
	CategoryComplexAnalysis       SubjectCategory = "Complex Analysis"
	CategoryAbstractAlgebra       SubjectCategory = "Abstract Algebra"
	CategoryTopology              SubjectCategory = "Topology"
	CategoryProbabilityStatistics SubjectCategory = "Probability & Statistics"
	CategoryDiscreteMath          SubjectCategory = "Discrete Math"
	CategoryDifferentialEquations SubjectCategory = "Differential Equations"
	CategoryGeometry              SubjectCategory = "Geometry"
	CategoryGeneralMath           SubjectCategory = "General Math"
)

// StudyMode identifies how a study session selects and grades cards.
type StudyMode string

const (
	StudyModeStandard StudyMode = "standard"
	StudyModeMixed    StudyMode = "mixed"
	StudyModeSurvival StudyMode = "survival"
)

// CardLayer represents one progressive-reveal hint or proof step on a card.
type CardLayer struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Content string `json:"content"`
}

// ReviewLog records a single spaced-repetition rating event for a flashcard.
type ReviewLog struct {
	Timestamp    string `json:"timestamp"`
	Rating       int    `json:"rating"`
	IntervalDays int    `json:"intervalDays"`
	DurationMs   *int64 `json:"durationMs,omitempty"`
}

// Deck groups flashcards under a mathematical discipline and optional chapters.
type Deck struct {
	ID          string          `json:"id"`
	UserID      string          `json:"userId"`
	Title       string          `json:"title"`
	Description string          `json:"description"`
	Category    SubjectCategory `json:"category"`
	Difficulty  Difficulty      `json:"difficulty"`
	Color       string          `json:"color"`
	CardCount   int             `json:"cardCount"`
	DueCount    int             `json:"dueCount"`
	Chapters    []string        `json:"chapters"`
	CreatedAt   string          `json:"createdAt"`
	UpdatedAt   string          `json:"updatedAt"`
}

// Flashcard holds multi-layer mathematical content and SM-2 scheduling state.
type Flashcard struct {
	ID             string      `json:"id"`
	DeckID         string      `json:"deckId"`
	UserID         string      `json:"userId"`
	Topic          string      `json:"topic,omitempty"`
	Order          int         `json:"order"`
	CardType       CardType    `json:"cardType,omitempty"`
	Front          string      `json:"front"`
	Back           string      `json:"back"`
	Layers         []CardLayer `json:"layers"`
	Explanation    string      `json:"explanation,omitempty"`
	Difficulty     Difficulty  `json:"difficulty"`
	Tags           []string    `json:"tags"`
	Repetition     int         `json:"repetition"`
	IntervalDays   int         `json:"intervalDays"`
	EaseFactor     float64     `json:"easeFactor"`
	NextReviewDate string      `json:"nextReviewDate"`
	LastReviewed   string      `json:"lastReviewed,omitempty"`
	TotalReviews   int         `json:"totalReviews"`
	CorrectCount   int         `json:"correctCount"`
	IncorrectCount int         `json:"incorrectCount"`
	History        []ReviewLog `json:"history"`
	CreatedAt      string      `json:"createdAt"`
	UpdatedAt      string      `json:"updatedAt"`
}

// StudySessionRecord captures a completed study or gauntlet run.
type StudySessionRecord struct {
	ID              string    `json:"id"`
	UserID          string    `json:"userId"`
	Mode            StudyMode `json:"mode"`
	DeckIDs         []string  `json:"deckIds"`
	DeckTitles      []string  `json:"deckTitles"`
	CardsReviewed   int       `json:"cardsReviewed"`
	CorrectCount    int       `json:"correctCount"`
	IncorrectCount  int       `json:"incorrectCount"`
	LivesLeft       *int      `json:"livesLeft,omitempty"`
	DurationSeconds int       `json:"durationSeconds"`
	CompletedAt     string    `json:"completedAt"`
}

// ActiveSessionState stores a crash-recovery snapshot of an in-progress study session.
type ActiveSessionState struct {
	SessionID       string    `json:"sessionId"`
	DeckID          string    `json:"deckId,omitempty"`
	DeckIDs         []string  `json:"deckIds"`
	Mode            StudyMode `json:"mode"`
	CurrentIndex    int       `json:"currentIndex"`
	CardIDs         []string  `json:"cardIds"`
	ReviewedCardIDs []string  `json:"reviewedCardIds"`
	CorrectCount    int       `json:"correctCount"`
	IncorrectCount  int       `json:"incorrectCount"`
	LivesLeft       *int      `json:"livesLeft,omitempty"`
	StartedAt       string    `json:"startedAt"`
}

// UserPreferences stores persisted display, audio, and study behavior settings.
type UserPreferences struct {
	FontFamily             string `json:"fontFamily"`
	FontSize               string `json:"fontSize"`
	RetroUIFont            string `json:"retroUIFont,omitempty"`
	Theme                  string `json:"theme"`
	ColorMode              string `json:"colorMode,omitempty"`
	SoundEnabled           bool   `json:"soundEnabled"`
	DefaultLives           int    `json:"defaultLives"`
	AutoRevealSteps        bool   `json:"autoRevealSteps"`
	ShowHelperDescriptions bool   `json:"showHelperDescriptions"`
	ClockStyle             string `json:"clockStyle,omitempty"`
}

// TransferCardsRequest specifies flashcards to move into a target deck and optional chapter topic.
type TransferCardsRequest struct {
	CardIDs      []string `json:"cardIds"`
	TargetDeckID string   `json:"targetDeckId"`
	TargetTopic  string   `json:"targetTopic,omitempty"`
	TargetIndex  *int     `json:"targetIndex,omitempty"`
}

// DefaultPreferences returns the standard initial UserPreferences.
func DefaultPreferences() UserPreferences {
	return UserPreferences{
		FontFamily:             "serif",
		FontSize:               "base",
		RetroUIFont:            "share-tech",
		Theme:                  "lunar-emerald",
		ColorMode:              "dark",
		SoundEnabled:           true,
		DefaultLives:           3,
		AutoRevealSteps:        false,
		ShowHelperDescriptions: false,
		ClockStyle:             "circular",
	}
}
