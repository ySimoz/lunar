package io_test

import (
	"strings"
	"testing"

	"lunar/core/internal/domain"
	lunario "lunar/core/internal/io"
)

func sampleDeckAndCards() (domain.Deck, []domain.Flashcard) {
	deck := domain.Deck{
		ID:          "deck-1",
		Title:       "Real Analysis & Calculus",
		Description: "Limits, continuity, and convergence.",
		Category:    domain.CategoryRealAnalysis,
		Difficulty:  domain.DifficultyHard,
		Color:       "emerald",
	}
	cards := []domain.Flashcard{
		{
			ID:          "c-1",
			DeckID:      "deck-1",
			Topic:       "Sequences",
			CardType:    domain.CardTypeDefinition,
			Front:       "Define a Cauchy sequence in $(X, d)$.",
			Back:        "For all $\\varepsilon > 0$, there exists $N$ such that $d(x_m, x_n) < \\varepsilon$ for $m, n \\ge N$.",
			Difficulty:  domain.DifficultyMedium,
			Tags:        []string{"cauchy", "metric-spaces"},
			Explanation: "In complete spaces, Cauchy iff convergent.",
			Layers: []domain.CardLayer{
				{ID: "l-1", Title: "Quantifier", Content: "Start with $\\forall \\varepsilon > 0$."},
				{ID: "l-2", Title: "Notation", Content: "Domain: $m,n \\ge N ::: d(x_m, x_n) < \\varepsilon$"},
			},
		},
		{
			ID:         "c-2",
			DeckID:     "deck-1",
			Topic:      "Series",
			CardType:   domain.CardTypeExample,
			Front:      "Evaluate $\\sum_{n=1}^{\\infty} 2^{-n}$.\nShow partial sums.",
			Back:       "Partial sum $S_k = 1 - 2^{-k}$,\nso the series converges to $1$.",
			Difficulty: domain.DifficultyEasy,
			Tags:       []string{"geometric"},
		},
	}
	return deck, cards
}

func TestJSONRoundTrip(t *testing.T) {
	deck, cards := sampleDeckAndCards()
	raw, err := lunario.ExportJSON(deck, cards)
	if err != nil {
		t.Fatalf("ExportJSON failed: %v", err)
	}

	parsed, err := lunario.ImportJSON(raw, lunario.ImportOptions{})
	if err != nil {
		t.Fatalf("ImportJSON failed: %v", err)
	}
	if parsed.Deck == nil || parsed.Deck.Title != deck.Title || parsed.Deck.Category != deck.Category {
		t.Fatalf("unexpected parsed deck: %+v", parsed.Deck)
	}
	if len(parsed.Cards) != 2 {
		t.Fatalf("len(parsed.Cards) = %d, want 2", len(parsed.Cards))
	}
	if parsed.Cards[0].Front != cards[0].Front || len(parsed.Cards[0].Layers) != 2 {
		t.Fatalf("card 0 mismatch: %+v", parsed.Cards[0])
	}
	if parsed.Cards[0].ID == cards[0].ID {
		t.Fatalf("expected fresh ID on import, still got %s", parsed.Cards[0].ID)
	}
}

func TestCSVRoundTrip_MultilineAndTripleColonInLayerContent(t *testing.T) {
	deck, cards := sampleDeckAndCards()
	csvText, err := lunario.ExportCSV(deck, cards)
	if err != nil {
		t.Fatalf("ExportCSV failed: %v", err)
	}

	parsed, err := lunario.ImportCSV(csvText, lunario.ImportOptions{NewDeckTitle: "Reimported CSV"})
	if err != nil {
		t.Fatalf("ImportCSV failed: %v", err)
	}
	if len(parsed.Cards) != 2 {
		t.Fatalf("len(parsed.Cards) = %d, want 2", len(parsed.Cards))
	}

	c0 := parsed.Cards[0]
	if c0.Difficulty != domain.DifficultyMedium || c0.Topic != "Sequences" || c0.CardType != domain.CardTypeDefinition {
		t.Fatalf("card 0 metadata lost: diff=%s topic=%q type=%s", c0.Difficulty, c0.Topic, c0.CardType)
	}
	if len(c0.Layers) != 2 {
		t.Fatalf("len(c0.Layers) = %d, want 2", len(c0.Layers))
	}
	// Layer 1 has ":::" inside its content; SplitN(..., 2) must keep the rest of content intact.
	if c0.Layers[1].Title != "Notation" || c0.Layers[1].Content != "Domain: $m,n \\ge N ::: d(x_m, x_n) < \\varepsilon$" {
		t.Fatalf("layer 1 mismatch: title=%q content=%q", c0.Layers[1].Title, c0.Layers[1].Content)
	}

	c1 := parsed.Cards[1]
	if c1.Front != cards[1].Front || c1.Back != cards[1].Back {
		t.Fatalf("multiline quoted CSV mismatch:\ngot front=%q back=%q\nwant front=%q back=%q", c1.Front, c1.Back, cards[1].Front, cards[1].Back)
	}
}

func TestCSVLegacy7ColumnCompatibility(t *testing.T) {
	legacy := "Front,Back,Layers,Category,Difficulty,Tags,Explanation\n" +
		"\"What is a group?\",\"Set with associative op, identity, inverses.\",\"Step 1:::Check closure|||Step 2:::Check a:::b\",\"Abstract Algebra\",\"hard\",\"algebra;groups\",\"Fundamental structure.\""

	parsed, err := lunario.ImportCSV(legacy, lunario.ImportOptions{NewDeckTitle: "Legacy"})
	if err != nil {
		t.Fatalf("ImportCSV legacy failed: %v", err)
	}
	if len(parsed.Cards) != 1 {
		t.Fatalf("len(parsed.Cards) = %d, want 1", len(parsed.Cards))
	}
	c := parsed.Cards[0]
	if c.Difficulty != domain.DifficultyHard || len(c.Layers) != 2 || len(c.Tags) != 2 || c.Explanation != "Fundamental structure." {
		t.Fatalf("unexpected legacy parsed card: %+v", c)
	}
	if parsed.Deck.Category != domain.CategoryAbstractAlgebra {
		t.Fatalf("deck category = %q, want Abstract Algebra", parsed.Deck.Category)
	}
}

func TestAnkiTSVRoundTrip(t *testing.T) {
	_, cards := sampleDeckAndCards()
	tsv := lunario.ExportAnkiTSV(cards)

	parsed, err := lunario.ImportAnkiTSV(tsv, lunario.ImportOptions{NewDeckTitle: "Anki Deck", TargetTopic: "Imported"})
	if err != nil {
		t.Fatalf("ImportAnkiTSV failed: %v", err)
	}
	if len(parsed.Cards) != 2 {
		t.Fatalf("len(parsed.Cards) = %d, want 2", len(parsed.Cards))
	}
	if !strings.Contains(parsed.Cards[1].Front, "\n") {
		t.Fatalf("expected <br> converted back to newline in Anki front, got %q", parsed.Cards[1].Front)
	}
	if parsed.Cards[0].CardType != domain.CardTypeDefinition {
		t.Fatalf("expected inferred Definition type, got %q", parsed.Cards[0].CardType)
	}
}

func TestMarkdownRoundTripAndItalianLabels(t *testing.T) {
	deck, cards := sampleDeckAndCards()
	md := lunario.ExportMarkdown(deck, cards)

	parsed, err := lunario.ImportMarkdown(md, lunario.ImportOptions{})
	if err != nil {
		t.Fatalf("ImportMarkdown round-trip failed: %v", err)
	}
	if parsed.Deck.Title != deck.Title || parsed.Deck.Category != deck.Category || parsed.Deck.Difficulty != deck.Difficulty {
		t.Fatalf("unexpected parsed deck: %+v", parsed.Deck)
	}
	if len(parsed.Cards) != 2 {
		t.Fatalf("len(parsed.Cards) = %d, want 2", len(parsed.Cards))
	}
	if parsed.Cards[0].Layers[0].Title != "Quantifier" {
		t.Fatalf("layer title = %q, want Quantifier", parsed.Cards[0].Layers[0].Title)
	}
	if len(parsed.Cards[0].Tags) != 2 || parsed.Cards[0].Tags[0] != "cauchy" {
		t.Fatalf("tags = %+v, want [cauchy metric-spaces]", parsed.Cards[0].Tags)
	}

	italianMD := `# Analisi Reale

## Card 1: Front
*Tipo:* Definizione

Definisci una successione limitata.

### Hint: Idea
Esiste $M > 0$ tale che $|a_n| \le M$.

### Back
Una successione $\{a_n\}$ è limitata se esiste $M > 0$ con $|a_n| \le M$ per ogni $n$.

*Tags:* ` + "`#analisi`" + ` ` + "`#successioni`" + `
`
	itParsed, err := lunario.ImportMarkdown(italianMD, lunario.ImportOptions{})
	if err != nil {
		t.Fatalf("ImportMarkdown Italian failed: %v", err)
	}
	if len(itParsed.Cards) != 1 || itParsed.Cards[0].CardType != domain.CardTypeDefinition {
		t.Fatalf("unexpected Italian card parse: %+v", itParsed.Cards)
	}
	if strings.Contains(itParsed.Cards[0].Front, "Tipo") {
		t.Fatalf("type metadata line was not stripped: %q", itParsed.Cards[0].Front)
	}
}

func TestImportUniqueIDsAndInvalidInputs(t *testing.T) {
	var b strings.Builder
	b.WriteString("Front,Back\n")
	for i := 0; i < 100; i++ {
		b.WriteString("Q,A\n")
	}
	parsed, err := lunario.ImportCSV(b.String(), lunario.ImportOptions{})
	if err != nil {
		t.Fatalf("ImportCSV 100 rows failed: %v", err)
	}
	seen := make(map[string]struct{}, len(parsed.Cards))
	for _, c := range parsed.Cards {
		if _, dup := seen[c.ID]; dup {
			t.Fatalf("duplicate generated card ID %q", c.ID)
		}
		seen[c.ID] = struct{}{}
	}

	for _, tc := range []struct {
		name    string
		format  lunario.Format
		content string
	}{
		{"empty json", lunario.FormatJSON, "   "},
		{"bad json", lunario.FormatJSON, "{bad"},
		{"empty cards json", lunario.FormatJSON, `{"version":"1.0","deck":{"title":"X"},"cards":[]}`},
		{"empty csv", lunario.FormatCSV, ""},
		{"header only csv", lunario.FormatCSV, "Front,Back\n"},
		{"bad anki", lunario.FormatAnki, "no tabs here"},
		{"empty md", lunario.FormatMarkdown, "# Just a heading\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := lunario.Import(tc.format, tc.content, lunario.ImportOptions{}); err == nil {
				t.Fatalf("expected error for %s", tc.name)
			}
		})
	}
}
