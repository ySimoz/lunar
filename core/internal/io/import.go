package io

import (
	"crypto/rand"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	stdIO "io"
	"regexp"
	"strings"
	"time"

	"lunar/core/internal/domain"
)

// ErrInvalidImport indicates malformed or empty import content.
var ErrInvalidImport = errors.New("invalid import content")

// ImportOptions configures deck/card defaults during import.
type ImportOptions struct {
	TargetDeckID string
	NewDeckTitle string
	Category     domain.SubjectCategory
	TargetTopic  string
}

// ImportParsed holds the deck metadata and cards parsed from an import payload.
type ImportParsed struct {
	Deck  *domain.Deck
	Cards []domain.Flashcard
}

var (
	typeLineRegex      = regexp.MustCompile(`(?i)^>?\s*[*_]*(?:Card\s+)?(?:Type|Tipo)[*_]*\s*:\s*[*_]*\s*` + "`?" + `\[?([a-zA-Zà-úÀ-Ú]+)\]?` + "`?" + `[*_]*\s*`)
	layerPrefixRegex   = regexp.MustCompile(`(?i)^###\s*(?:Layer\s+\d+\s*:\s*)?`)
	brTagRegex         = regexp.MustCompile(`(?i)<br\s*/?>`)
	markdownTagRegex   = regexp.MustCompile("`?#([^`\\s,]+)`?")
	definitionFrontRe  = regexp.MustCompile(`(?i)^(define|definition|definisci|definizione|cosa si intende|cos'è|what is (the )?definition|state the definition)`)
	exampleFrontRe     = regexp.MustCompile(`(?i)^(example|problem|problema|esercizio|calcola|determina|risolvi|trova|calculate|compute|evaluate|find the|determine the|solve|find all)`)
)

// Import parses content in the specified format into deck metadata and normalized Flashcards.
func Import(format Format, content string, opts ImportOptions) (ImportParsed, error) {
	if strings.TrimSpace(content) == "" {
		return ImportParsed{}, fmt.Errorf("%w: content cannot be empty", ErrInvalidImport)
	}

	switch format {
	case FormatJSON:
		return ImportJSON(content, opts)
	case FormatCSV:
		return ImportCSV(content, opts)
	case FormatAnki:
		return ImportAnkiTSV(content, opts)
	case FormatMarkdown:
		return ImportMarkdown(content, opts)
	default:
		return ImportParsed{}, fmt.Errorf("%w: unsupported format %q", ErrInvalidImport, format)
	}
}

// ImportJSON parses a Lunar JSON export bundle ({ version, exportedAt, deck, cards }).
func ImportJSON(content string, opts ImportOptions) (ImportParsed, error) {
	var bundle ExportBundle
	dec := json.NewDecoder(strings.NewReader(content))
	if err := dec.Decode(&bundle); err != nil {
		return ImportParsed{}, fmt.Errorf("%w: malformed JSON: %v", ErrInvalidImport, err)
	}
	var trailing any
	if err := dec.Decode(&trailing); err != stdIO.EOF {
		return ImportParsed{}, fmt.Errorf("%w: trailing JSON data", ErrInvalidImport)
	}
	if len(bundle.Cards) == 0 {
		return ImportParsed{}, fmt.Errorf("%w: JSON bundle contains no cards", ErrInvalidImport)
	}

	var parsedDeck *domain.Deck
	if opts.TargetDeckID == "" {
		d := bundle.Deck
		d.ID = ""
		if strings.TrimSpace(opts.NewDeckTitle) != "" {
			d.Title = strings.TrimSpace(opts.NewDeckTitle)
		}
		if strings.TrimSpace(d.Title) == "" {
			d.Title = "Imported Deck"
		}
		if opts.Category != "" {
			d.Category = opts.Category
		}
		parsedDeck = &d
	}

	cards := make([]domain.Flashcard, 0, len(bundle.Cards))
	for i, c := range bundle.Cards {
		if strings.TrimSpace(c.Front) == "" || strings.TrimSpace(c.Back) == "" {
			return ImportParsed{}, fmt.Errorf("%w: card %d is missing front or back", ErrInvalidImport, i+1)
		}
		c.ID = newID("card")
		c.DeckID = opts.TargetDeckID
		if c.Topic == "" && opts.TargetTopic != "" {
			c.Topic = opts.TargetTopic
		}
		if c.CardType == "" {
			c.CardType = InferCardType(c.Front, c.Back, c.Tags)
		}
		if c.Difficulty == "" {
			c.Difficulty = domain.DifficultyMedium
		}
		layers := make([]domain.CardLayer, 0, len(c.Layers))
		for _, l := range c.Layers {
			l.ID = newID("layer")
			layers = append(layers, l)
		}
		c.Layers = layers
		cards = append(cards, c)
	}

	return ImportParsed{Deck: parsedDeck, Cards: cards}, nil
}

// ImportCSV parses CSV content using encoding/csv with header-aware column mapping
// and backward-compatible support for legacy 7-column web CSVs.
func ImportCSV(content string, opts ImportOptions) (ImportParsed, error) {
	r := csv.NewReader(strings.NewReader(content))
	r.FieldsPerRecord = -1 // allow variable trailing optional columns across rows

	records, err := r.ReadAll()
	if err != nil {
		return ImportParsed{}, fmt.Errorf("%w: malformed CSV: %v", ErrInvalidImport, err)
	}
	if len(records) == 0 {
		return ImportParsed{}, fmt.Errorf("%w: empty CSV", ErrInvalidImport)
	}

	colIdx, hasHeader := detectCSVHeader(records[0])
	if hasHeader {
		records = records[1:]
	}

	var detectedCategory domain.SubjectCategory
	cards := make([]domain.Flashcard, 0, len(records))
	for _, row := range records {
		if isBlankRow(row) {
			continue
		}
		if len(row) < 2 {
			continue
		}

		var front, back, layersRaw, catRaw, diffRaw, topic, tagsRaw, explanation, typeRaw string
		if hasHeader {
			front = cellAt(row, colIdx, "front")
			back = cellAt(row, colIdx, "back")
			layersRaw = cellAt(row, colIdx, "layers")
			catRaw = cellAt(row, colIdx, "category")
			diffRaw = cellAt(row, colIdx, "difficulty")
			topic = strings.TrimSpace(cellAt(row, colIdx, "topic"))
			tagsRaw = cellAt(row, colIdx, "tags")
			explanation = cellAt(row, colIdx, "explanation")
			typeRaw = firstNonEmpty(
				cellAt(row, colIdx, "cardtype"),
				cellAt(row, colIdx, "card_type"),
				cellAt(row, colIdx, "type"),
			)
		} else {
			front = row[0]
			back = row[1]
			if len(row) > 2 {
				layersRaw = row[2]
			}
			if len(row) > 3 {
				catRaw = row[3]
			}
			if len(row) >= 9 {
				diffRaw = row[4]
				topic = strings.TrimSpace(row[5])
				tagsRaw = row[6]
				explanation = row[7]
				typeRaw = row[8]
			} else {
				// Legacy 7-col web CSV fallback: col 4 can be either difficulty or topic.
				if len(row) > 4 {
					cand := strings.TrimSpace(row[4])
					if domain.Difficulty(strings.ToLower(cand)).IsValid() {
						diffRaw = cand
					} else {
						topic = cand
					}
				}
				if len(row) > 5 {
					tagsRaw = row[5]
				}
				if len(row) > 6 {
					explanation = row[6]
				}
				if len(row) > 7 {
					typeRaw = row[7]
				}
			}
		}

		if strings.TrimSpace(front) == "" || strings.TrimSpace(back) == "" {
			continue
		}
		if detectedCategory == "" {
			if c := domain.SubjectCategory(strings.TrimSpace(catRaw)); c.IsValid() {
				detectedCategory = c
			}
		}
		if topic == "" {
			topic = opts.TargetTopic
		}

		layers := parseCSVLayers(layersRaw)
		tags := splitCSVTags(tagsRaw)
		difficulty := domain.Difficulty(strings.ToLower(strings.TrimSpace(diffRaw)))
		if !difficulty.IsValid() {
			difficulty = domain.DifficultyMedium
		}
		cardType := ResolveCardType(typeRaw, front, back, tags)

		card := newImportedCard(opts.TargetDeckID, front, back, layers, tags, topic, cardType, difficulty, explanation)
		cards = append(cards, card)
	}

	if len(cards) == 0 {
		return ImportParsed{}, fmt.Errorf("%w: no valid cards found in CSV", ErrInvalidImport)
	}

	var parsedDeck *domain.Deck
	if opts.TargetDeckID == "" {
		cat := opts.Category
		if cat == "" {
			cat = detectedCategory
		}
		if cat == "" {
			cat = domain.CategoryGeneralMath
		}
		title := strings.TrimSpace(opts.NewDeckTitle)
		if title == "" {
			title = "Imported CSV Deck"
		}
		parsedDeck = &domain.Deck{
			Title:      title,
			Category:   cat,
			Difficulty: domain.DifficultyMedium,
		}
	}

	return ImportParsed{Deck: parsedDeck, Cards: cards}, nil
}

// ImportAnkiTSV parses tab-separated Front\tBack\tTags[\tTopic] lines.
func ImportAnkiTSV(content string, opts ImportOptions) (ImportParsed, error) {
	lines := strings.Split(content, "\n")
	cards := make([]domain.Flashcard, 0, len(lines))

	for _, rawLine := range lines {
		line := strings.TrimSpace(strings.TrimSuffix(rawLine, "\r"))
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) < 2 {
			continue
		}
		front := strings.TrimSpace(brTagRegex.ReplaceAllString(parts[0], "\n"))
		back := strings.TrimSpace(brTagRegex.ReplaceAllString(parts[1], "\n"))
		if front == "" || back == "" {
			continue
		}
		var tags []string
		if len(parts) > 2 {
			tags = strings.Fields(parts[2])
		}
		topic := opts.TargetTopic
		if len(parts) > 3 && strings.TrimSpace(parts[3]) != "" {
			topic = strings.TrimSpace(parts[3])
		}
		cardType := InferCardType(front, back, tags)
		cards = append(cards, newImportedCard(opts.TargetDeckID, front, back, nil, tags, topic, cardType, domain.DifficultyMedium, ""))
	}

	if len(cards) == 0 {
		return ImportParsed{}, fmt.Errorf("%w: no valid tab-separated cards found", ErrInvalidImport)
	}

	var parsedDeck *domain.Deck
	if opts.TargetDeckID == "" {
		cat := opts.Category
		if cat == "" {
			cat = domain.CategoryGeneralMath
		}
		title := strings.TrimSpace(opts.NewDeckTitle)
		if title == "" {
			title = "Imported Anki Deck"
		}
		parsedDeck = &domain.Deck{
			Title:      title,
			Category:   cat,
			Difficulty: domain.DifficultyMedium,
		}
	}

	return ImportParsed{Deck: parsedDeck, Cards: cards}, nil
}

// ImportMarkdown parses Lunar structured Markdown into deck metadata and cards.
func ImportMarkdown(content string, opts ImportOptions) (ImportParsed, error) {
	lines := strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n")

	type mdSection int
	const (
		secNone mdSection = iota
		secFront
		secLayer
		secBack
		secExplanation
	)

	var (
		deckTitle         string
		deckCat           domain.SubjectCategory
		deckDiff          domain.Difficulty
		cards             []domain.Flashcard
		currentFront      strings.Builder
		currentBack       strings.Builder
		currentExpl       strings.Builder
		currentLayers     []domain.CardLayer
		currentTags       []string
		currentCardType   domain.CardType
		currentSection    = secNone
		currentLayerTitle string
		currentLayerBody  strings.Builder
	)

	flushLayer := func() {
		if currentLayerTitle != "" && strings.TrimSpace(currentLayerBody.String()) != "" {
			currentLayers = append(currentLayers, domain.CardLayer{
				ID:      newID("layer"),
				Title:   currentLayerTitle,
				Content: strings.TrimSpace(currentLayerBody.String()),
			})
		}
		currentLayerTitle = ""
		currentLayerBody.Reset()
	}

	saveCard := func() {
		flushLayer()
		cleanFront, frontType := ExtractAndStripType(currentFront.String())
		cleanBack, backType := ExtractAndStripType(currentBack.String())

		if cleanFront != "" && (cleanBack != "" || len(currentLayers) > 0) {
			resolvedType := currentCardType
			if resolvedType == "" {
				resolvedType = frontType
			}
			if resolvedType == "" {
				resolvedType = backType
			}
			if resolvedType == "" {
				resolvedType = InferCardType(cleanFront, cleanBack, currentTags)
			}
			if cleanBack == "" {
				cleanBack = "See steps above"
			}
			card := newImportedCard(
				opts.TargetDeckID,
				cleanFront,
				cleanBack,
				currentLayers,
				currentTags,
				opts.TargetTopic,
				resolvedType,
				domain.DifficultyMedium,
				strings.TrimSpace(currentExpl.String()),
			)
			cards = append(cards, card)
		}

		currentFront.Reset()
		currentBack.Reset()
		currentExpl.Reset()
		currentLayers = nil
		currentTags = nil
		currentCardType = ""
		currentSection = secNone
	}

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		if strings.HasPrefix(line, "# ") && deckTitle == "" {
			deckTitle = strings.TrimSpace(strings.TrimPrefix(line, "# "))
			continue
		}

		if strings.HasPrefix(trimmed, "> **Category:**") && currentSection == secNone {
			deckCat, deckDiff = parseMarkdownDeckMeta(trimmed)
			continue
		}

		if strings.HasPrefix(line, "## ") || trimmed == "---" {
			if strings.TrimSpace(currentFront.String()) != "" {
				saveCard()
			}
			if strings.HasPrefix(line, "## ") {
				currentSection = secFront
				rawTitle := strings.TrimSpace(strings.TrimPrefix(line, "## "))
				if parsedType := ParseCardType(rawTitle); parsedType != "" {
					currentCardType = parsedType
				}
				if !strings.Contains(strings.ToLower(rawTitle), "card") {
					currentFront.WriteString(rawTitle)
					currentFront.WriteByte('\n')
				}
			}
			continue
		}

		if currentSection == secNone {
			if trimmed != "" && !strings.HasPrefix(line, "#") && !strings.HasPrefix(line, ">") && trimmed != "---" {
				currentSection = secFront
			}
		}

		if loc := typeLineRegex.FindStringSubmatchIndex(line); loc != nil {
			val := line[loc[2]:loc[3]]
			if parsed := ParseCardType(val); parsed != "" {
				currentCardType = parsed
				rest := strings.TrimSpace(line[loc[1]:])
				if rest != "" && currentSection == secFront {
					currentFront.WriteString(rest)
					currentFront.WriteByte('\n')
				}
				continue
			}
		}

		if strings.HasPrefix(line, "### Layer") || strings.HasPrefix(line, "### Step") || strings.HasPrefix(line, "### Hint") {
			flushLayer()
			title := strings.TrimSpace(layerPrefixRegex.ReplaceAllString(line, ""))
			if title == "" {
				title = fmt.Sprintf("Step %d", len(currentLayers)+1)
			}
			currentLayerTitle = title
			currentSection = secLayer
			continue
		}

		if strings.HasPrefix(line, "### Answer") || strings.HasPrefix(line, "### Back") {
			flushLayer()
			currentSection = secBack
			continue
		}

		if strings.HasPrefix(line, "*Explanation") || strings.HasPrefix(line, "Explanation:") {
			currentSection = secExplanation
			if idx := strings.Index(line, ":"); idx >= 0 {
				rest := strings.TrimSpace(strings.TrimPrefix(line[idx+1:], "*"))
				if rest != "" {
					currentExpl.WriteString(rest)
					currentExpl.WriteByte('\n')
				}
			}
			continue
		}

		if strings.HasPrefix(line, "*Tags:*") || strings.HasPrefix(line, "Tags:") {
			matches := markdownTagRegex.FindAllStringSubmatch(line, -1)
			for _, m := range matches {
				tag := strings.TrimSpace(m[1])
				if tag != "" {
					currentTags = append(currentTags, tag)
				}
			}
			if currentCardType == "" {
				for _, t := range currentTags {
					if parsed := ParseCardType(t); parsed != "" {
						currentCardType = parsed
						break
					}
				}
			}
			continue
		}

		switch currentSection {
		case secFront:
			currentFront.WriteString(line)
			currentFront.WriteByte('\n')
		case secLayer:
			currentLayerBody.WriteString(line)
			currentLayerBody.WriteByte('\n')
		case secBack:
			currentBack.WriteString(line)
			currentBack.WriteByte('\n')
		case secExplanation:
			currentExpl.WriteString(line)
			currentExpl.WriteByte('\n')
		}
	}

	saveCard()

	if len(cards) == 0 {
		return ImportParsed{}, fmt.Errorf("%w: no valid cards found in Markdown", ErrInvalidImport)
	}

	var parsedDeck *domain.Deck
	if opts.TargetDeckID == "" {
		title := strings.TrimSpace(opts.NewDeckTitle)
		if title == "" {
			title = deckTitle
		}
		if title == "" {
			title = "Imported Markdown Deck"
		}
		cat := opts.Category
		if cat == "" {
			cat = deckCat
		}
		if cat == "" {
			cat = domain.CategoryGeneralMath
		}
		diff := deckDiff
		if !diff.IsValid() {
			diff = domain.DifficultyMedium
		}
		parsedDeck = &domain.Deck{
			Title:      title,
			Category:   cat,
			Difficulty: diff,
		}
	}

	return ImportParsed{Deck: parsedDeck, Cards: cards}, nil
}

// ParseCardType maps English/Italian type labels to a domain.CardType.
func ParseCardType(val string) domain.CardType {
	s := strings.ToLower(strings.TrimSpace(val))
	if s == "" {
		return ""
	}
	if strings.Contains(s, "def") ||
		strings.Contains(s, "terminolog") ||
		strings.Contains(s, "axiom") ||
		strings.Contains(s, "assiom") ||
		strings.Contains(s, "concetto") {
		return domain.CardTypeDefinition
	}
	if strings.Contains(s, "examp") ||
		strings.Contains(s, "esemp") ||
		strings.Contains(s, "prob") ||
		strings.Contains(s, "exerc") ||
		strings.Contains(s, "eserc") ||
		strings.Contains(s, "calcul") ||
		strings.Contains(s, "calcol") ||
		strings.Contains(s, "comput") ||
		strings.Contains(s, "applicaz") {
		return domain.CardTypeExample
	}
	if strings.Contains(s, "theor") ||
		strings.Contains(s, "teor") ||
		strings.Contains(s, "lemma") ||
		strings.Contains(s, "coroll") ||
		strings.Contains(s, "prop") ||
		strings.Contains(s, "proof") ||
		strings.Contains(s, "dimostr") {
		return domain.CardTypeTheorem
	}
	return ""
}

// ExtractAndStripType strips explicit Type/Tipo metadata lines and returns the detected CardType.
func ExtractAndStripType(text string) (string, domain.CardType) {
	if text == "" {
		return "", ""
	}
	var detected domain.CardType
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	filtered := make([]string, 0, len(lines))

	for _, line := range lines {
		if loc := typeLineRegex.FindStringSubmatchIndex(line); loc != nil {
			if parsed := ParseCardType(line[loc[2]:loc[3]]); parsed != "" && detected == "" {
				detected = parsed
			}
			if rem := strings.TrimSpace(line[loc[1]:]); rem != "" {
				filtered = append(filtered, rem)
			}
			continue
		}
		filtered = append(filtered, line)
	}
	return strings.TrimSpace(strings.Join(filtered, "\n")), detected
}

// InferCardType infers a CardType from tags, front prompt, and back answer.
func InferCardType(front, back string, tags []string) domain.CardType {
	for _, t := range tags {
		if matched := ParseCardType(t); matched != "" {
			return matched
		}
	}
	cleanFront := strings.ToLower(strings.TrimSpace(front))
	combined := strings.ToLower(front + " " + back)

	if definitionFrontRe.MatchString(cleanFront) ||
		strings.Contains(combined, "**definition:**") ||
		strings.Contains(combined, "**definizione:**") ||
		strings.Contains(combined, "definition:") ||
		strings.Contains(combined, "definizione:") ||
		strings.HasPrefix(cleanFront, "define ") ||
		strings.HasPrefix(cleanFront, "definisci ") ||
		strings.Contains(combined, "is defined as") ||
		strings.Contains(combined, "si definisce come") ||
		strings.Contains(combined, "is called a") ||
		strings.Contains(combined, "si dice") {
		return domain.CardTypeDefinition
	}

	if exampleFrontRe.MatchString(cleanFront) ||
		strings.Contains(combined, "**example:**") ||
		strings.Contains(combined, "**problem:**") ||
		strings.Contains(combined, "**esempio:**") ||
		strings.Contains(combined, "**esercizio:**") ||
		strings.Contains(combined, "example:") ||
		strings.Contains(combined, "problem:") ||
		strings.Contains(combined, "esempio:") ||
		strings.HasPrefix(cleanFront, "calculate ") ||
		strings.HasPrefix(cleanFront, "calcola ") ||
		strings.HasPrefix(cleanFront, "compute ") ||
		strings.HasPrefix(cleanFront, "evaluate ") {
		return domain.CardTypeExample
	}

	return domain.CardTypeTheorem
}

// ResolveCardType prefers an explicit type string, falling back to InferCardType.
func ResolveCardType(explicit, front, back string, tags []string) domain.CardType {
	if parsed := ParseCardType(explicit); parsed != "" {
		return parsed
	}
	return InferCardType(front, back, tags)
}

func detectCSVHeader(row []string) (map[string]int, bool) {
	idx := make(map[string]int, len(row))
	for i, col := range row {
		key := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(col, "\ufeff")))
		if key != "" {
			idx[key] = i
		}
	}
	_, hasFront := idx["front"]
	_, hasBack := idx["back"]
	return idx, hasFront && hasBack
}

func cellAt(row []string, idx map[string]int, key string) string {
	pos, ok := idx[key]
	if !ok || pos < 0 || pos >= len(row) {
		return ""
	}
	return row[pos]
}

func isBlankRow(row []string) bool {
	for _, cell := range row {
		if strings.TrimSpace(cell) != "" {
			return false
		}
	}
	return true
}

func parseCSVLayers(raw string) []domain.CardLayer {
	if strings.TrimSpace(raw) == "" {
		return []domain.CardLayer{}
	}
	parts := strings.Split(raw, "|||")
	layers := make([]domain.CardLayer, 0, len(parts))
	for idx, lp := range parts {
		if strings.TrimSpace(lp) == "" {
			continue
		}
		kv := strings.SplitN(lp, ":::", 2)
		var title, body string
		if len(kv) == 2 {
			title = strings.TrimSpace(kv[0])
			body = kv[1]
		} else {
			body = lp
		}
		if title == "" {
			title = fmt.Sprintf("Step %d", idx+1)
		}
		if strings.TrimSpace(body) == "" {
			body = title
		}
		layers = append(layers, domain.CardLayer{
			ID:      newID("layer"),
			Title:   title,
			Content: body,
		})
	}
	return layers
}

func splitCSVTags(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return []string{}
	}
	parts := strings.Split(raw, ";")
	tags := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			tags = append(tags, t)
		}
	}
	return tags
}

func parseMarkdownDeckMeta(line string) (domain.SubjectCategory, domain.Difficulty) {
	var cat domain.SubjectCategory
	var diff domain.Difficulty
	for _, seg := range strings.Split(strings.TrimPrefix(line, ">"), "|") {
		seg = strings.TrimSpace(seg)
		if strings.Contains(seg, "**Category:**") {
			val := strings.TrimSpace(strings.ReplaceAll(seg, "**Category:**", ""))
			if c := domain.SubjectCategory(val); c.IsValid() {
				cat = c
			}
		}
		if strings.Contains(seg, "**Difficulty:**") {
			val := strings.ToLower(strings.TrimSpace(strings.ReplaceAll(seg, "**Difficulty:**", "")))
			if d := domain.Difficulty(val); d.IsValid() {
				diff = d
			}
		}
	}
	return cat, diff
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func newImportedCard(
	deckID, front, back string,
	layers []domain.CardLayer,
	tags []string,
	topic string,
	cardType domain.CardType,
	difficulty domain.Difficulty,
	explanation string,
) domain.Flashcard {
	now := time.Now().UTC().Format(time.RFC3339)
	if layers == nil {
		layers = []domain.CardLayer{}
	}
	if tags == nil {
		tags = []string{}
	}
	return domain.Flashcard{
		ID:             newID("card"),
		DeckID:         deckID,
		UserID:         "default",
		Topic:          topic,
		CardType:       cardType,
		Front:          front,
		Back:           back,
		Layers:         layers,
		Explanation:    explanation,
		Difficulty:     difficulty,
		Tags:           tags,
		IntervalDays:   1,
		EaseFactor:     2.5,
		NextReviewDate: now,
		History:        []domain.ReviewLog{},
		CreatedAt:      now,
		UpdatedAt:      now,
	}
}

func newID(prefix string) string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("%s-%s", prefix, hex.EncodeToString(b[:]))
}
