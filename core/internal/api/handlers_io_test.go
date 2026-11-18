package api_test

import (
	"archive/zip"
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	_ "github.com/mattn/go-sqlite3"

	"lunar/core/internal/domain"
	"lunar/core/internal/store"
)

func buildAPITestAPKG(t *testing.T, deckTitle string, notes [][2]string) []byte {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "collection.anki21")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatalf("open temp anki sqlite: %v", err)
	}
	_, err = db.Exec(`
		CREATE TABLE col (id INTEGER PRIMARY KEY, decks TEXT NOT NULL, models TEXT NOT NULL);
		CREATE TABLE notes (id INTEGER PRIMARY KEY, mid INTEGER NOT NULL, tags TEXT NOT NULL, flds TEXT NOT NULL);
		CREATE TABLE cards (id INTEGER PRIMARY KEY, nid INTEGER NOT NULL, did INTEGER NOT NULL, ord INTEGER NOT NULL);
	`)
	if err != nil {
		t.Fatalf("create anki schema: %v", err)
	}
	decksJSON, _ := json.Marshal(map[string]any{
		"10": map[string]any{"id": 10, "name": deckTitle},
	})
	_, _ = db.Exec(`INSERT INTO col (id, decks, models) VALUES (1, ?, '{}')`, string(decksJSON))
	for i, n := range notes {
		nid := int64(i + 1)
		_, _ = db.Exec(`INSERT INTO notes (id, mid, tags, flds) VALUES (?, 1, 'math', ?)`, nid, n[0]+"\x1f"+n[1])
		_, _ = db.Exec(`INSERT INTO cards (id, nid, did, ord) VALUES (?, ?, 10, 0)`, nid, nid)
	}
	_ = db.Close()

	dbBytes, err := os.ReadFile(dbPath)
	if err != nil {
		t.Fatalf("read temp anki sqlite: %v", err)
	}

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	fw, err := zw.Create("collection.anki21")
	if err != nil {
		t.Fatalf("zip create: %v", err)
	}
	_, _ = fw.Write(dbBytes)
	_ = zw.Close()
	return buf.Bytes()
}

func TestBackupAndRestoreHTTPHandlers(t *testing.T) {
	h := newTestServer(t)

	// 1. Export backup
	backupReq := httptest.NewRequest(http.MethodGet, "/api/backup", nil)
	backupRec := httptest.NewRecorder()
	h.ServeHTTP(backupRec, backupReq)

	if backupRec.Code != http.StatusOK {
		t.Fatalf("GET /api/backup = %d: %s", backupRec.Code, backupRec.Body.String())
	}
	if ct := backupRec.Header().Get("Content-Type"); ct != "application/octet-stream" {
		t.Fatalf("Content-Type = %q, want application/octet-stream", ct)
	}
	if cd := backupRec.Header().Get("Content-Disposition"); !strings.Contains(cd, `filename="lunar-backup.db"`) {
		t.Fatalf("Content-Disposition = %q, want lunar-backup.db", cd)
	}
	backupBytes := backupRec.Body.Bytes()
	if !bytes.HasPrefix(backupBytes, []byte("SQLite format 3\x00")) {
		t.Fatalf("backup response is not a SQLite 3 file")
	}

	// 2. Mutate library
	createRes := doJSON(t, h, http.MethodPost, "/api/decks", domain.Deck{
		Title:      "Temporary Deck",
		Category:   domain.CategoryGeometry,
		Difficulty: domain.DifficultyEasy,
	})
	if createRes.Code != http.StatusCreated {
		t.Fatalf("create deck = %d", createRes.Code)
	}

	// 3. Reject corrupt restore without touching live DB
	badRestoreReq := httptest.NewRequest(http.MethodPost, "/api/restore", bytes.NewReader([]byte("corrupt payload")))
	badRestoreRec := httptest.NewRecorder()
	h.ServeHTTP(badRestoreRec, badRestoreReq)
	if badRestoreRec.Code != http.StatusBadRequest {
		t.Fatalf("POST /api/restore corrupt = %d, want 400", badRestoreRec.Code)
	}

	decksMidRes := doJSON(t, h, http.MethodGet, "/api/decks", nil)
	var midDecks []domain.Deck
	_ = json.Unmarshal(decksMidRes.Body.Bytes(), &midDecks)
	if len(midDecks) != 5 {
		t.Fatalf("expected 5 decks intact after rejected restore, got %d", len(midDecks))
	}

	// 4. Valid restore reverts to 4 seeded decks and 16 cards
	restoreReq := httptest.NewRequest(http.MethodPost, "/api/restore", bytes.NewReader(backupBytes))
	restoreRec := httptest.NewRecorder()
	h.ServeHTTP(restoreRec, restoreReq)
	if restoreRec.Code != http.StatusOK {
		t.Fatalf("POST /api/restore = %d: %s", restoreRec.Code, restoreRec.Body.String())
	}
	var counts store.RestoreCounts
	if err := json.Unmarshal(restoreRec.Body.Bytes(), &counts); err != nil {
		t.Fatalf("decode restore counts: %v", err)
	}
	if counts.Decks != 4 || counts.Cards != 16 {
		t.Fatalf("restore counts = %+v, want {Decks:4 Cards:16}", counts)
	}

	decksAfterRes := doJSON(t, h, http.MethodGet, "/api/decks", nil)
	var afterDecks []domain.Deck
	_ = json.Unmarshal(decksAfterRes.Body.Bytes(), &afterDecks)
	if len(afterDecks) != 4 {
		t.Fatalf("expected 4 decks after restore, got %d", len(afterDecks))
	}
}

func TestImportAPKGHTTPHandler(t *testing.T) {
	h := newTestServer(t)

	apkgBytes := buildAPITestAPKG(t, "Differential Geometry", [][2]string{
		{"<div>Define a <b>manifold</b>.</div>", "Locally Euclidean Hausdorff second-countable space."},
		{"State Gauss-Bonnet.", `\(\int_M K\,dA = 2\pi\chi(M)\)`},
	})

	// 1. Import into new deck using deck_name query param
	req := httptest.NewRequest(http.MethodPost, "/api/io/import/apkg?deck_name=DiffGeom", bytes.NewReader(apkgBytes))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("POST /api/io/import/apkg = %d: %s", rec.Code, rec.Body.String())
	}

	var res struct {
		Deck          domain.Deck        `json:"deck"`
		ImportedCount int                `json:"importedCount"`
		Cards         []domain.Flashcard `json:"cards"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
		t.Fatalf("decode apkg import result: %v", err)
	}
	if res.Deck.Title != "DiffGeom" || res.ImportedCount != 2 || len(res.Cards) != 2 {
		t.Fatalf("unexpected import result: %+v", res)
	}

	// 2. Re-import into same deck_id with skip_duplicates=true -> 0 imported
	dupReq := httptest.NewRequest(
		http.MethodPost,
		"/api/io/import/apkg?deck_id="+res.Deck.ID+"&skip_duplicates=true",
		bytes.NewReader(apkgBytes),
	)
	dupRec := httptest.NewRecorder()
	h.ServeHTTP(dupRec, dupReq)
	if dupRec.Code != http.StatusOK {
		t.Fatalf("POST /api/io/import/apkg skip_duplicates = %d: %s", dupRec.Code, dupRec.Body.String())
	}
	var dupRes struct {
		ImportedCount int                `json:"importedCount"`
		Cards         []domain.Flashcard `json:"cards"`
	}
	if err := json.Unmarshal(dupRec.Body.Bytes(), &dupRes); err != nil {
		t.Fatalf("decode dup import result: %v", err)
	}
	if dupRes.ImportedCount != 0 || len(dupRes.Cards) != 0 {
		t.Fatalf("expected 0 imported on duplicate skip, got %+v", dupRes)
	}

	// 3. Invalid .apkg returns 400; missing deck_id returns 404
	badReq := httptest.NewRequest(http.MethodPost, "/api/io/import/apkg", bytes.NewReader([]byte("bad zip")))
	badRec := httptest.NewRecorder()
	h.ServeHTTP(badRec, badReq)
	if badRec.Code != http.StatusBadRequest {
		t.Fatalf("invalid apkg status = %d, want 400", badRec.Code)
	}

	missingReq := httptest.NewRequest(http.MethodPost, "/api/io/import/apkg?deck_id=does-not-exist", bytes.NewReader(apkgBytes))
	missingRec := httptest.NewRecorder()
	h.ServeHTTP(missingRec, missingReq)
	if missingRec.Code != http.StatusNotFound {
		t.Fatalf("missing deck_id status = %d, want 404", missingRec.Code)
	}
}
