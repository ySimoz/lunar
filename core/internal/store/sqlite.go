// Package store provides SQLite persistence for Lunar decks, cards, sessions, and preferences.
package store

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

var (
	// ErrNotFound indicates the requested record does not exist.
	ErrNotFound = errors.New("record not found")
	// ErrValidation indicates input failed domain or structural validation.
	ErrValidation = errors.New("validation failed")
)

// Store wraps the SQLite database connection and schema migrations.
type Store struct {
	mu   sync.RWMutex
	db   *sql.DB
	path string
}

// Open opens (or creates) a SQLite database at path, configures WAL + foreign keys, and runs migrations.
func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite3", sqliteDSN(path))
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	// Single connection prevents SQLite write contention and shares :memory: state across queries.
	db.SetMaxOpenConns(1)

	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}

	s := &Store{db: db, path: path}
	if err := s.migrate(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("migrate schema: %w", err)
	}
	return s, nil
}

// Close closes the underlying SQLite connection.
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return nil
	}
	return s.db.Close()
}

// DB exposes the underlying sql.DB for verification in tests.
func (s *Store) DB() *sql.DB {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.db
}

func isMemorySQLitePath(path string) bool {
	return path == ":memory:" ||
		strings.HasPrefix(path, "file::memory:") ||
		strings.Contains(path, "mode=memory")
}

func sqliteDSN(path string) string {
	isMemory := isMemorySQLitePath(path)

	base, rawQuery, hasQuery := strings.Cut(path, "?")
	vals, err := url.ParseQuery(rawQuery)
	if err != nil {
		sep := "?"
		if hasQuery {
			sep = "&"
		}
		params := "_foreign_keys=on&_busy_timeout=5000"
		if !isMemory {
			params += "&_journal_mode=WAL"
		}
		return path + sep + params
	}
	if !vals.Has("_foreign_keys") {
		vals.Set("_foreign_keys", "on")
	}
	if !vals.Has("_busy_timeout") {
		vals.Set("_busy_timeout", "5000")
	}
	if !isMemory && !vals.Has("_journal_mode") {
		vals.Set("_journal_mode", "WAL")
	}
	return base + "?" + vals.Encode()
}

func (s *Store) migrate() error {
	return migrateDB(s.db)
}

func migrateDB(db *sql.DB) error {
	if _, err := db.Exec(schemaSQL); err != nil {
		return err
	}
	return ensureDeckOrderColumn(db)
}

// ensureDeckOrderColumn adds deck_order to pre-existing SQLite databases.
func ensureDeckOrderColumn(db *sql.DB) error {
	rows, err := db.Query(`PRAGMA table_info(decks)`)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var cid int
		var name, ctype string
		var notnull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			return err
		}
		if name == "deck_order" {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = db.Exec(`ALTER TABLE decks ADD COLUMN deck_order INTEGER NOT NULL DEFAULT 0`)
	return err
}

func newID(prefix string) string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("%s-%s", prefix, hex.EncodeToString(b[:]))
}

func nowISO() string {
	return time.Now().UTC().Format(time.RFC3339)
}

func encodeStringSlice(items []string) string {
	if len(items) == 0 {
		return "[]"
	}
	raw, err := json.Marshal(items)
	if err != nil {
		return "[]"
	}
	return string(raw)
}

func decodeStringSlice(raw string) []string {
	if raw == "" {
		return []string{}
	}
	var out []string
	if err := json.Unmarshal([]byte(raw), &out); err != nil || out == nil {
		return []string{}
	}
	return out
}
