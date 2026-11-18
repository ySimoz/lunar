package io

import (
	"archive/zip"
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"html"
	stdIO "io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	_ "github.com/mattn/go-sqlite3"

	"lunar/core/internal/domain"
)

const maxAPKGCollectionBytes = 128 << 20 // 128 MiB

var (
	ankiBlockOpenRe  = regexp.MustCompile(`(?i)<(?:div|p|li|tr|h[1-6]|blockquote)\b[^>]*>`)
	ankiBlockCloseRe = regexp.MustCompile(`(?i)</(?:div|p|li|tr|h[1-6]|blockquote)>`)
	ankiHRRe         = regexp.MustCompile(`(?i)<hr\s*/?>`)
	ankiTagRe        = regexp.MustCompile(`(?s)<[^>]+>`)
	ankiMultiNLRe    = regexp.MustCompile(`\n{3,}`)

	ankiLegacyLatexBlockRe = regexp.MustCompile(`(?is)\[(?:latex|\$\$)\]([\s\S]*?)\[/(?:latex|\$\$)\]`)
	ankiLegacyLatexInlRe   = regexp.MustCompile(`(?is)\[\$\]([\s\S]*?)\[/\$\]`)

	mathSpanPatterns = []*regexp.Regexp{
		regexp.MustCompile(`\$\$[\s\S]*?\$\$`),
		regexp.MustCompile(`\\\[[\s\S]*?\\\]`),
		regexp.MustCompile(`\\\([\s\S]*?\\\)`),
		regexp.MustCompile(`\$[^$\n]+?\$`),
	}

	clozePattern = regexp.MustCompile(`\{\{c\d+::([\s\S]*?)(?:::([\s\S]*?))?\}\}`)
)

type ankiDeckMeta struct {
	Name string `json:"name"`
}

type ankiModelMeta struct {
	Type int `json:"type"`
}

type ankiNoteRow struct {
	id   int64
	mid  int64
	tags string
	flds string
}

// ImportAPKG parses a binary Anki .apkg archive into deck metadata and normalized Flashcards.
func ImportAPKG(data []byte, opts ImportOptions) (ImportParsed, error) {
	if len(data) == 0 {
		return ImportParsed{}, fmt.Errorf("%w: empty .apkg archive", ErrInvalidImport)
	}

	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return ImportParsed{}, fmt.Errorf("%w: invalid .apkg zip archive: %v", ErrInvalidImport, err)
	}

	anki21File := findZipEntry(zr.File, "collection.anki21")
	anki2File := findZipEntry(zr.File, "collection.anki2")
	anki21bFile := findZipEntry(zr.File, "collection.anki21b")

	if anki21File == nil && anki2File == nil {
		if anki21bFile != nil {
			return ImportParsed{}, fmt.Errorf("%w: unsupported .apkg format (collection.anki21b); export with legacy compatibility enabled in Anki", ErrInvalidImport)
		}
		return ImportParsed{}, fmt.Errorf("%w: .apkg archive does not contain collection.anki21 or collection.anki2", ErrInvalidImport)
	}

	var parsed ImportParsed
	var parseErr error

	if anki21File != nil {
		var dbBytes []byte
		dbBytes, err = readZipEntryLimited(anki21File, maxAPKGCollectionBytes)
		if err == nil {
			parsed, parseErr = parseAnkiCollectionSQLite(dbBytes, opts, true)
			if parseErr == nil && len(parsed.Cards) > 0 {
				return parsed, nil
			}
		} else {
			parseErr = err
		}
	}

	if anki2File != nil {
		dbBytes, err := readZipEntryLimited(anki2File, maxAPKGCollectionBytes)
		if err != nil {
			return ImportParsed{}, fmt.Errorf("%w: read collection.anki2: %v", ErrInvalidImport, err)
		}
		// Skip Anki 2.1 stub placeholder notice if collection.anki21 was present.
		skipStub := anki21File != nil
		parsed2, err2 := parseAnkiCollectionSQLite(dbBytes, opts, skipStub)
		if err2 == nil && len(parsed2.Cards) > 0 {
			return parsed2, nil
		}
		if parseErr == nil {
			parseErr = err2
		}
	}

	if parseErr != nil {
		return ImportParsed{}, parseErr
	}
	return ImportParsed{}, fmt.Errorf("%w: no valid cards found in .apkg archive", ErrInvalidImport)
}

func findZipEntry(files []*zip.File, target string) *zip.File {
	for _, f := range files {
		if f.FileInfo().IsDir() {
			continue
		}
		if f.Name == target {
			return f
		}
	}
	for _, f := range files {
		if f.FileInfo().IsDir() {
			continue
		}
		if path.Base(f.Name) == target {
			return f
		}
	}
	return nil
}

func readZipEntryLimited(f *zip.File, limit int64) ([]byte, error) {
	rc, err := f.Open()
	if err != nil {
		return nil, err
	}
	defer rc.Close()

	data, err := stdIO.ReadAll(stdIO.LimitReader(rc, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%w: collection database exceeds %d bytes", ErrInvalidImport, limit)
	}
	return data, nil
}

func parseAnkiCollectionSQLite(dbBytes []byte, opts ImportOptions, skipStubNotice bool) (ImportParsed, error) {
	if len(dbBytes) < 100 || !bytes.HasPrefix(dbBytes, []byte("SQLite format 3\x00")) {
		return ImportParsed{}, fmt.Errorf("%w: .apkg collection is not a valid SQLite database", ErrInvalidImport)
	}

	tmpDir, err := os.MkdirTemp("", "lunar-apkg-*")
	if err != nil {
		return ImportParsed{}, fmt.Errorf("create apkg temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	dbPath := filepath.Join(tmpDir, "collection.sqlite")
	if err := os.WriteFile(dbPath, dbBytes, 0o600); err != nil {
		return ImportParsed{}, fmt.Errorf("write apkg temp db: %w", err)
	}

	db, err := sql.Open("sqlite3", dbPath+"?_busy_timeout=5000")
	if err != nil {
		return ImportParsed{}, fmt.Errorf("%w: open apkg sqlite: %v", ErrInvalidImport, err)
	}
	db.SetMaxOpenConns(1)
	defer db.Close()

	decksMap, modelsMap, err := readAnkiColMetadata(db)
	if err != nil {
		return ImportParsed{}, err
	}

	noteDeckID, err := readAnkiNoteDeckMap(db)
	if err != nil {
		return ImportParsed{}, err
	}

	notes, err := readAnkiNotes(db)
	if err != nil {
		return ImportParsed{}, err
	}

	didCounts := make(map[int64]int)
	cards := make([]domain.Flashcard, 0, len(notes))

	for _, n := range notes {
		rawFields := strings.Split(n.flds, "\x1f")
		if len(rawFields) == 0 {
			continue
		}

		front := cleanAnkiHTML(rawFields[0])
		if skipStubNotice && isAnkiStubNotice(front) {
			continue
		}

		backParts := make([]string, 0, max(0, len(rawFields)-1))
		for _, rf := range rawFields[1:] {
			cleaned := cleanAnkiHTML(rf)
			if cleaned != "" {
				backParts = append(backParts, cleaned)
			}
		}
		back := strings.Join(backParts, "\n\n")

		isCloze := clozePattern.MatchString(front)
		if !isCloze {
			if m, ok := modelsMap[strconv.FormatInt(n.mid, 10)]; ok && m.Type == 1 {
				isCloze = true
			}
		}
		if back == "" && isCloze {
			back = extractClozeBack(front)
		}

		if front == "" || back == "" {
			continue
		}

		tags := strings.Fields(n.tags)
		did := noteDeckID[n.id]
		if did != 0 {
			didCounts[did]++
		}

		topic := strings.TrimSpace(opts.TargetTopic)
		if topic == "" && did != 0 {
			if dm, ok := decksMap[strconv.FormatInt(did, 10)]; ok {
				if _, sub, hasSub := strings.Cut(dm.Name, "::"); hasSub {
					topic = strings.TrimSpace(sub)
				}
			}
		}

		cardType := InferCardType(front, back, tags)
		card := newImportedCard(
			opts.TargetDeckID,
			front,
			back,
			nil,
			tags,
			topic,
			cardType,
			domain.DifficultyMedium,
			"",
		)
		cards = append(cards, card)
	}

	if len(cards) == 0 {
		return ImportParsed{}, fmt.Errorf("%w: no valid notes found in .apkg collection", ErrInvalidImport)
	}

	var parsedDeck *domain.Deck
	if opts.TargetDeckID == "" {
		title := strings.TrimSpace(opts.NewDeckTitle)
		if title == "" {
			title = resolvePrimaryAnkiDeckName(decksMap, didCounts)
		}
		if title == "" {
			title = "Imported Anki Deck"
		}
		cat := opts.Category
		if cat == "" {
			cat = domain.CategoryGeneralMath
		}
		parsedDeck = &domain.Deck{
			Title:      title,
			Category:   cat,
			Difficulty: domain.DifficultyMedium,
		}
	}

	return ImportParsed{Deck: parsedDeck, Cards: cards}, nil
}

func readAnkiColMetadata(db *sql.DB) (map[string]ankiDeckMeta, map[string]ankiModelMeta, error) {
	var decksJSON, modelsJSON sql.NullString
	err := db.QueryRow(`SELECT decks, models FROM col LIMIT 1`).Scan(&decksJSON, &modelsJSON)
	if err != nil {
		// Some custom/minimal Anki DBs might omit col or have different col schema; fail only if notes fails.
		return map[string]ankiDeckMeta{}, map[string]ankiModelMeta{}, nil
	}

	decksMap := map[string]ankiDeckMeta{}
	if decksJSON.Valid && strings.TrimSpace(decksJSON.String) != "" {
		_ = json.Unmarshal([]byte(decksJSON.String), &decksMap)
	}

	modelsMap := map[string]ankiModelMeta{}
	if modelsJSON.Valid && strings.TrimSpace(modelsJSON.String) != "" {
		_ = json.Unmarshal([]byte(modelsJSON.String), &modelsMap)
	}

	return decksMap, modelsMap, nil
}

func readAnkiNoteDeckMap(db *sql.DB) (map[int64]int64, error) {
	rows, err := db.Query(`SELECT nid, did FROM cards ORDER BY id ASC`)
	if err != nil {
		// Allow notes-only synthetic DBs if cards table is absent, otherwise return error?
		// Standard Anki collections always have cards; if missing, ignore gracefully.
		return map[int64]int64{}, nil
	}
	defer rows.Close()

	noteDeck := make(map[int64]int64)
	for rows.Next() {
		var nid, did int64
		if err := rows.Scan(&nid, &did); err != nil {
			return nil, fmt.Errorf("%w: scan apkg card row: %v", ErrInvalidImport, err)
		}
		if _, exists := noteDeck[nid]; !exists {
			noteDeck[nid] = did
		}
	}
	return noteDeck, rows.Err()
}

func readAnkiNotes(db *sql.DB) ([]ankiNoteRow, error) {
	rows, err := db.Query(`SELECT id, mid, tags, flds FROM notes ORDER BY id ASC`)
	if err != nil {
		return nil, fmt.Errorf("%w: query apkg notes: %v", ErrInvalidImport, err)
	}
	defer rows.Close()

	var notes []ankiNoteRow
	for rows.Next() {
		var n ankiNoteRow
		var tags, flds sql.NullString
		if err := rows.Scan(&n.id, &n.mid, &tags, &flds); err != nil {
			return nil, fmt.Errorf("%w: scan apkg note: %v", ErrInvalidImport, err)
		}
		n.tags = tags.String
		n.flds = flds.String
		notes = append(notes, n)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: iterate apkg notes: %v", ErrInvalidImport, err)
	}
	return notes, nil
}

func resolvePrimaryAnkiDeckName(decksMap map[string]ankiDeckMeta, didCounts map[int64]int) string {
	bestName := ""
	bestCount := -1
	for did, count := range didCounts {
		dm, ok := decksMap[strconv.FormatInt(did, 10)]
		if !ok {
			continue
		}
		name := topLevelDeckName(dm.Name)
		if name == "" || strings.EqualFold(name, "Default") {
			continue
		}
		if count > bestCount {
			bestCount = count
			bestName = name
		}
	}
	if bestName != "" {
		return bestName
	}

	for _, dm := range decksMap {
		name := topLevelDeckName(dm.Name)
		if name != "" && !strings.EqualFold(name, "Default") {
			return name
		}
	}
	return ""
}

func topLevelDeckName(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	root, _, _ := strings.Cut(trimmed, "::")
	return strings.TrimSpace(root)
}

func isAnkiStubNotice(front string) bool {
	lower := strings.ToLower(front)
	return strings.Contains(lower, "please update to the latest anki version") ||
		strings.Contains(lower, "import the .colpkg/.apkg file again")
}

func extractClozeBack(front string) string {
	matches := clozePattern.FindAllStringSubmatch(front, -1)
	if len(matches) == 0 {
		return ""
	}
	answers := make([]string, 0, len(matches))
	for _, m := range matches {
		ans := strings.TrimSpace(m[1])
		if ans != "" {
			answers = append(answers, ans)
		}
	}
	if len(answers) > 0 {
		return strings.Join(answers, "; ")
	}
	return strings.TrimSpace(clozePattern.ReplaceAllString(front, "$1"))
}

// cleanAnkiHTML strips basic Anki HTML formatting (<br>, <div>, <b>, <i>, &nbsp;, etc.)
// while preserving LaTeX expressions (\(...\), \[...\], $$...$$, $...$) and cloze syntax.
func cleanAnkiHTML(raw string) string {
	if strings.TrimSpace(raw) == "" {
		return ""
	}

	working := strings.ReplaceAll(raw, "\r\n", "\n")
	working = ankiLegacyLatexBlockRe.ReplaceAllStringFunc(working, func(m string) string {
		sub := ankiLegacyLatexBlockRe.FindStringSubmatch(m)
		if len(sub) < 2 {
			return m
		}
		return "$$" + sub[1] + "$$"
	})
	working = ankiLegacyLatexInlRe.ReplaceAllStringFunc(working, func(m string) string {
		sub := ankiLegacyLatexInlRe.FindStringSubmatch(m)
		if len(sub) < 2 {
			return m
		}
		return "$" + sub[1] + "$"
	})

	var mathSlots []string
	for _, re := range mathSpanPatterns {
		working = re.ReplaceAllStringFunc(working, func(match string) string {
			unescaped := strings.ReplaceAll(html.UnescapeString(match), "\u00a0", " ")
			token := fmt.Sprintf("\x00LUNAR_MATH_%d\x00", len(mathSlots))
			mathSlots = append(mathSlots, unescaped)
			return token
		})
	}

	working = brTagRegex.ReplaceAllString(working, "\n")
	working = ankiHRRe.ReplaceAllString(working, "\n")
	working = ankiBlockCloseRe.ReplaceAllString(working, "\n")
	working = ankiBlockOpenRe.ReplaceAllString(working, "\n")
	working = ankiTagRe.ReplaceAllString(working, "")
	working = html.UnescapeString(working)
	working = strings.ReplaceAll(working, "\u00a0", " ")

	for i, expr := range mathSlots {
		working = strings.ReplaceAll(working, fmt.Sprintf("\x00LUNAR_MATH_%d\x00", i), expr)
	}

	lines := strings.Split(working, "\n")
	for i, line := range lines {
		lines[i] = strings.TrimSpace(line)
	}
	working = strings.Join(lines, "\n")
	working = ankiMultiNLRe.ReplaceAllString(working, "\n\n")
	return strings.TrimSpace(working)
}
