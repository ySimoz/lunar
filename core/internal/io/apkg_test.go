package io_test

import (
	"archive/zip"
	"bytes"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	_ "github.com/mattn/go-sqlite3"

	lunario "lunar/core/internal/io"
)

type ankiTestNote struct {
	id   int64
	mid  int64
	did  int64
	tags string
	flds string
}

func buildTestAnkiSQLite(t *testing.T, decksJSON, modelsJSON string, notes []ankiTestNote) []byte {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "collection.sqlite")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatalf("open temp anki sqlite: %v", err)
	}
	defer db.Close()

	_, err = db.Exec(`
		CREATE TABLE col (
			id INTEGER PRIMARY KEY,
			decks TEXT NOT NULL,
			models TEXT NOT NULL
		);
		CREATE TABLE notes (
			id INTEGER PRIMARY KEY,
			mid INTEGER NOT NULL,
			tags TEXT NOT NULL,
			flds TEXT NOT NULL
		);
		CREATE TABLE cards (
			id INTEGER PRIMARY KEY,
			nid INTEGER NOT NULL,
			did INTEGER NOT NULL,
			ord INTEGER NOT NULL
		);
	`)
	if err != nil {
		t.Fatalf("create anki schema: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO col (id, decks, models) VALUES (1, ?, ?)`, decksJSON, modelsJSON); err != nil {
		t.Fatalf("insert col: %v", err)
	}
	for i, n := range notes {
		if _, err := db.Exec(`INSERT INTO notes (id, mid, tags, flds) VALUES (?, ?, ?, ?)`, n.id, n.mid, n.tags, n.flds); err != nil {
			t.Fatalf("insert note %d: %v", n.id, err)
		}
		if _, err := db.Exec(`INSERT INTO cards (id, nid, did, ord) VALUES (?, ?, ?, 0)`, int64(i+1), n.id, n.did); err != nil {
			t.Fatalf("insert card %d: %v", i+1, err)
		}
	}
	_ = db.Close()

	raw, err := os.ReadFile(dbPath)
	if err != nil {
		t.Fatalf("read temp anki sqlite: %v", err)
	}
	return raw
}

func buildTestAPKGZip(t *testing.T, entries map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, content := range entries {
		fw, err := zw.Create(name)
		if err != nil {
			t.Fatalf("zip create %s: %v", name, err)
		}
		if _, err := fw.Write(content); err != nil {
			t.Fatalf("zip write %s: %v", name, err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("zip close: %v", err)
	}
	return buf.Bytes()
}

func TestImportAPKG_PrefersAnki21AndCleansHTMLPreservingLaTeXAndCloze(t *testing.T) {
	decksJSON := `{
		"1": {"id": 1, "name": "Default"},
		"100": {"id": 100, "name": "Real Analysis::Measure Theory"}
	}`
	modelsJSON := `{
		"10": {"id": 10, "type": 0},
		"20": {"id": 20, "type": 1}
	}`

	anki21DB := buildTestAnkiSQLite(t, decksJSON, modelsJSON, []ankiTestNote{
		{
			id:   1,
			mid:  10,
			did:  100,
			tags: " analysis theorem ",
			flds: "<div><b>State Monotone Convergence</b><br>Given \\(0 \\le f_n &lt; f_{n+1}\\)</div>\x1f<div>Then \\[\\int f_n \\to \\int f\\] &amp; $$\\lim_{n \\to \\infty} f_n = f$$&nbsp;a.e.</div>",
		},
		{
			id:   2,
			mid:  20,
			did:  100,
			tags: "cloze topology",
			flds: "Every {{c1::compact}} subset of a {{c2::Hausdorff::T2}} space is closed.\x1f",
		},
	})

	// Stub collection.anki2 should be ignored because collection.anki21 has notes.
	anki2StubDB := buildTestAnkiSQLite(t, `{"1":{"name":"Default"}}`, `{}`, []ankiTestNote{
		{
			id:   999,
			mid:  10,
			did:  1,
			tags: "",
			flds: "Please update to the latest Anki version, then import the .colpkg/.apkg file again.\x1fSee AnkiWeb.",
		},
	})

	apkgBytes := buildTestAPKGZip(t, map[string][]byte{
		"collection.anki21": anki21DB,
		"collection.anki2":  anki2StubDB,
	})

	parsed, err := lunario.ImportAPKG(apkgBytes, lunario.ImportOptions{})
	if err != nil {
		t.Fatalf("ImportAPKG failed: %v", err)
	}
	if parsed.Deck == nil || parsed.Deck.Title != "Real Analysis" {
		t.Fatalf("parsed.Deck = %+v, want Title 'Real Analysis'", parsed.Deck)
	}
	if len(parsed.Cards) != 2 {
		t.Fatalf("len(parsed.Cards) = %d, want 2", len(parsed.Cards))
	}

	c0 := parsed.Cards[0]
	if strings.Contains(c0.Front, "<div") || strings.Contains(c0.Front, "<b>") || strings.Contains(c0.Front, "<br") {
		t.Fatalf("HTML tags remained in front: %q", c0.Front)
	}
	if !strings.Contains(c0.Front, `\(0 \le f_n < f_{n+1}\)`) {
		t.Fatalf("LaTeX with < was damaged in front: %q", c0.Front)
	}
	if !strings.Contains(c0.Back, `\[\int f_n \to \int f\]`) || !strings.Contains(c0.Back, `$$\lim_{n \to \infty} f_n = f$$`) {
		t.Fatalf("LaTeX delimiters were not preserved in back: %q", c0.Back)
	}
	if strings.Contains(c0.Back, "&nbsp;") || strings.Contains(c0.Back, "&amp;") {
		t.Fatalf("HTML entities not unescaped in back: %q", c0.Back)
	}
	if c0.Topic != "Measure Theory" {
		t.Fatalf("c0.Topic = %q, want 'Measure Theory'", c0.Topic)
	}
	if len(c0.Tags) != 2 || c0.Tags[0] != "analysis" || c0.Tags[1] != "theorem" {
		t.Fatalf("c0.Tags = %+v, want [analysis theorem]", c0.Tags)
	}

	c1 := parsed.Cards[1]
	if !strings.Contains(c1.Front, "{{c1::compact}}") || !strings.Contains(c1.Front, "{{c2::Hausdorff::T2}}") {
		t.Fatalf("cloze syntax lost in front: %q", c1.Front)
	}
	if c1.Back != "compact; Hausdorff" {
		t.Fatalf("c1.Back = %q, want 'compact; Hausdorff'", c1.Back)
	}
}

func TestImportAPKG_FallbacksAndInvalidInputs(t *testing.T) {
	anki2DB := buildTestAnkiSQLite(
		t,
		`{"1":{"name":"Default"},"42":{"name":"Linear Algebra"}}`,
		`{"1":{"type":0}}`,
		[]ankiTestNote{
			{
				id:   1,
				mid:  1,
				did:  42,
				tags: "definition",
				flds: "Define <i>eigenvalue</i>.\x1fA scalar $\\lambda$ with $Av = \\lambda v$ for $v \\ne 0$.",
			},
		},
	)

	apkgBytes := buildTestAPKGZip(t, map[string][]byte{
		"collection.anki2": anki2DB,
	})

	parsed, err := lunario.ImportAPKG(apkgBytes, lunario.ImportOptions{
		NewDeckTitle: "Custom LA",
		TargetTopic:  "Spectral Theory",
	})
	if err != nil {
		t.Fatalf("ImportAPKG fallback collection.anki2 failed: %v", err)
	}
	if parsed.Deck.Title != "Custom LA" {
		t.Fatalf("Deck.Title = %q, want 'Custom LA'", parsed.Deck.Title)
	}
	if len(parsed.Cards) != 1 || parsed.Cards[0].Topic != "Spectral Theory" {
		t.Fatalf("unexpected cards: %+v", parsed.Cards)
	}

	invalidCases := []struct {
		name string
		data []byte
	}{
		{"empty", nil},
		{"not a zip", []byte("not a zip archive")},
		{"missing collection db", buildTestAPKGZip(t, map[string][]byte{"media": []byte("{}")})},
		{"anki21b only", buildTestAPKGZip(t, map[string][]byte{"collection.anki21b": []byte("proto")})},
	}
	for _, tc := range invalidCases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := lunario.ImportAPKG(tc.data, lunario.ImportOptions{}); !errors.Is(err, lunario.ErrInvalidImport) {
				t.Fatalf("ImportAPKG(%s) err = %v, want ErrInvalidImport", tc.name, err)
			}
		})
	}
}
