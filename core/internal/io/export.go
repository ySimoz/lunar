// Package io implements export and import across JSON, CSV, Anki TSV, and Markdown formats.
package io

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"strings"
	"time"
	"unicode"

	"lunar/core/internal/domain"
)

// Format identifies a supported deck export/import format.
type Format string

const (
	FormatJSON     Format = "json"
	FormatCSV      Format = "csv"
	FormatAnki     Format = "anki"
	FormatMarkdown Format = "md"
)

// ParseFormat normalizes a format string into a supported Format.
func ParseFormat(raw string) (Format, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "json":
		return FormatJSON, nil
	case "csv":
		return FormatCSV, nil
	case "anki", "tsv", "txt":
		return FormatAnki, nil
	case "md", "markdown":
		return FormatMarkdown, nil
	default:
		return "", fmt.Errorf("unsupported format %q: must be json, csv, anki, or md", raw)
	}
}

// ExportBundle is the canonical JSON export envelope.
type ExportBundle struct {
	Version    string             `json:"version"`
	ExportedAt string             `json:"exportedAt"`
	Deck       domain.Deck        `json:"deck"`
	Cards      []domain.Flashcard `json:"cards"`
}

// ExportResult holds rendered export content and download metadata.
type ExportResult struct {
	Filename string `json:"filename"`
	Content  string `json:"content"`
	MimeType string `json:"mimeType"`
}

// ExportDeck renders deck and cards in the requested format.
func ExportDeck(deck domain.Deck, cards []domain.Flashcard, format Format) (ExportResult, error) {
	if cards == nil {
		cards = []domain.Flashcard{}
	}
	slug := slugifyFilename(deck.Title)

	switch format {
	case FormatJSON:
		content, err := ExportJSON(deck, cards)
		if err != nil {
			return ExportResult{}, err
		}
		return ExportResult{
			Filename: slug + ".json",
			Content:  content,
			MimeType: "application/json",
		}, nil
	case FormatCSV:
		content, err := ExportCSV(deck, cards)
		if err != nil {
			return ExportResult{}, err
		}
		return ExportResult{
			Filename: slug + ".csv",
			Content:  content,
			MimeType: "text/csv; charset=utf-8",
		}, nil
	case FormatAnki:
		return ExportResult{
			Filename: slug + "-anki.txt",
			Content:  ExportAnkiTSV(cards),
			MimeType: "text/plain; charset=utf-8",
		}, nil
	case FormatMarkdown:
		return ExportResult{
			Filename: slug + ".md",
			Content:  ExportMarkdown(deck, cards),
			MimeType: "text/markdown; charset=utf-8",
		}, nil
	default:
		return ExportResult{}, fmt.Errorf("unsupported export format %q", format)
	}
}

// ExportJSON serializes deck and cards into a versioned JSON bundle.
func ExportJSON(deck domain.Deck, cards []domain.Flashcard) (string, error) {
	if cards == nil {
		cards = []domain.Flashcard{}
	}
	bundle := ExportBundle{
		Version:    "1.0",
		ExportedAt: time.Now().UTC().Format(time.RFC3339),
		Deck:       deck,
		Cards:      cards,
	}
	raw, err := json.MarshalIndent(bundle, "", "  ")
	if err != nil {
		return "", fmt.Errorf("marshal export json: %w", err)
	}
	return string(raw), nil
}

// ExportCSV serializes cards with RFC 4180 CSV quoting and all 9 Lunar columns.
func ExportCSV(deck domain.Deck, cards []domain.Flashcard) (string, error) {
	var buf bytes.Buffer
	w := csv.NewWriter(&buf)

	headers := []string{"Front", "Back", "Layers", "Category", "Difficulty", "Topic", "Tags", "Explanation", "CardType"}
	if err := w.Write(headers); err != nil {
		return "", fmt.Errorf("write csv header: %w", err)
	}

	for _, c := range cards {
		layerParts := make([]string, 0, len(c.Layers))
		for _, l := range c.Layers {
			layerParts = append(layerParts, l.Title+":::"+l.Content)
		}
		row := []string{
			c.Front,
			c.Back,
			strings.Join(layerParts, "|||"),
			string(deck.Category),
			string(c.Difficulty),
			c.Topic,
			strings.Join(c.Tags, ";"),
			c.Explanation,
			string(c.CardType),
		}
		if err := w.Write(row); err != nil {
			return "", fmt.Errorf("write csv row: %w", err)
		}
	}
	w.Flush()
	if err := w.Error(); err != nil {
		return "", fmt.Errorf("flush csv: %w", err)
	}
	return strings.TrimSuffix(buf.String(), "\n"), nil
}

// ExportAnkiTSV serializes cards as tab-separated Front\tBack\tTags lines with <br> line breaks.
func ExportAnkiTSV(cards []domain.Flashcard) string {
	lines := make([]string, 0, len(cards))
	for _, c := range cards {
		backContent := c.Back
		if len(c.Layers) > 0 {
			layerHTML := make([]string, 0, len(c.Layers))
			for _, l := range c.Layers {
				layerHTML = append(layerHTML, fmt.Sprintf("<b>%s:</b> %s", l.Title, l.Content))
			}
			backContent += "<br><hr><b>Step-by-step Layers:</b><br>" + strings.Join(layerHTML, "<br>")
		}
		if c.Explanation != "" {
			backContent += "<br><i>Note:</i> " + c.Explanation
		}
		cleanFront := sanitizeTSVField(c.Front)
		cleanBack := sanitizeTSVField(backContent)
		tags := strings.Join(c.Tags, " ")
		lines = append(lines, cleanFront+"\t"+cleanBack+"\t"+tags)
	}
	return strings.Join(lines, "\n")
}

// ExportMarkdown renders the deck and cards into structured Lunar Markdown.
func ExportMarkdown(deck domain.Deck, cards []domain.Flashcard) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", deck.Title)
	fmt.Fprintf(&b, "> **Category:** %s | **Difficulty:** %s\n", deck.Category, deck.Difficulty)
	if strings.TrimSpace(deck.Description) != "" {
		fmt.Fprintf(&b, "> %s\n", deck.Description)
	}
	b.WriteString("\n---\n\n")

	for idx, c := range cards {
		typeLabel := cardTypeLabel(c.CardType)
		fmt.Fprintf(&b, "## Card %d (%s): Front\n\n", idx+1, typeLabel)
		fmt.Fprintf(&b, "*Type:* `%s`\n\n", typeLabel)
		fmt.Fprintf(&b, "%s\n\n", c.Front)

		for lIdx, l := range c.Layers {
			fmt.Fprintf(&b, "### Layer %d: %s\n\n%s\n\n", lIdx+1, l.Title, l.Content)
		}

		fmt.Fprintf(&b, "### Answer / Back\n\n%s\n\n", c.Back)
		if strings.TrimSpace(c.Explanation) != "" {
			fmt.Fprintf(&b, "*Explanation / Derivation:*\n%s\n\n", c.Explanation)
		}
		if len(c.Tags) > 0 {
			tagTokens := make([]string, 0, len(c.Tags))
			for _, t := range c.Tags {
				tagTokens = append(tagTokens, fmt.Sprintf("`#%s`", t))
			}
			fmt.Fprintf(&b, "*Tags:* %s\n\n", strings.Join(tagTokens, " "))
		}
		b.WriteString("---\n\n")
	}

	return b.String()
}

func sanitizeTSVField(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\t", "  ")
	s = strings.ReplaceAll(s, "\n", "<br>")
	return s
}

func cardTypeLabel(t domain.CardType) string {
	switch t {
	case domain.CardTypeDefinition:
		return "Definition"
	case domain.CardTypeExample:
		return "Example"
	default:
		return "Theorem"
	}
}

func slugifyFilename(title string) string {
	var b strings.Builder
	prevDash := false
	for _, r := range strings.ToLower(strings.TrimSpace(title)) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
			prevDash = false
		} else if !prevDash && b.Len() > 0 {
			b.WriteByte('-')
			prevDash = true
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		return "lunar-deck"
	}
	return out
}
