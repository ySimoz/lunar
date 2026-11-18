package store

import (
	"bytes"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var sqliteMagicHeader = []byte("SQLite format 3\x00")

// RestoreCounts summarizes the library counts after a successful database restore.
type RestoreCounts struct {
	Decks int `json:"decks"`
	Cards int `json:"cards"`
}

// Backup exports a consistent, WAL-safe SQLite snapshot using VACUUM INTO.
func (s *Store) Backup() ([]byte, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.db == nil {
		return nil, errors.New("store is closed")
	}

	tmpDir, err := os.MkdirTemp("", "lunar-backup-*")
	if err != nil {
		return nil, fmt.Errorf("create backup temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	backupPath := filepath.Join(tmpDir, "lunar-backup.db")
	escapedPath := strings.ReplaceAll(backupPath, "'", "''")
	if _, err := s.db.Exec(fmt.Sprintf("VACUUM INTO '%s'", escapedPath)); err != nil {
		return nil, fmt.Errorf("vacuum into backup: %w", err)
	}

	data, err := os.ReadFile(backupPath)
	if err != nil {
		return nil, fmt.Errorf("read backup snapshot: %w", err)
	}
	return data, nil
}

// Restore validates a SQLite backup payload, atomically swaps the live database file,
// runs schema migrations, and rolls back to a .bak copy on any error.
func (s *Store) Restore(data []byte) (RestoreCounts, error) {
	if err := validateBackupBytes(data); err != nil {
		return RestoreCounts{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.db == nil {
		return RestoreCounts{}, errors.New("store is closed")
	}
	if isMemorySQLitePath(s.path) {
		return RestoreCounts{}, fmt.Errorf("%w: restore is not supported for in-memory databases", ErrValidation)
	}

	// Flush WAL pages into the main database file before closing.
	_, _ = s.db.Exec("PRAGMA wal_checkpoint(TRUNCATE)")
	if err := s.db.Close(); err != nil {
		return RestoreCounts{}, fmt.Errorf("close live database: %w", err)
	}
	s.db = nil

	bakPath := s.path + ".bak"
	stagingPath := s.path + ".restore.tmp"
	_ = os.Remove(bakPath)
	_ = os.Remove(stagingPath)

	hasOriginal := false
	if _, err := os.Stat(s.path); err == nil {
		if err := os.Rename(s.path, bakPath); err != nil {
			reopened, reopenErr := openLiveDB(s.path)
			if reopenErr == nil {
				s.db = reopened
			}
			return RestoreCounts{}, fmt.Errorf("backup live database: %w", err)
		}
		hasOriginal = true
	}

	_ = os.Remove(s.path + "-wal")
	_ = os.Remove(s.path + "-shm")

	rollback := func(cause error, failedDB *sql.DB) (RestoreCounts, error) {
		if failedDB != nil {
			_ = failedDB.Close()
		}
		_ = os.Remove(stagingPath)
		_ = os.Remove(s.path + "-wal")
		_ = os.Remove(s.path + "-shm")
		_ = os.Remove(s.path)
		if hasOriginal {
			_ = os.Rename(bakPath, s.path)
		}
		if restoredOrig, err := openLiveDB(s.path); err == nil {
			s.db = restoredOrig
		}
		return RestoreCounts{}, cause
	}

	if err := writeFileSync(stagingPath, data); err != nil {
		return rollback(fmt.Errorf("write restore staging file: %w", err), nil)
	}
	if err := os.Rename(stagingPath, s.path); err != nil {
		return rollback(fmt.Errorf("swap restored database: %w", err), nil)
	}

	newDB, err := openLiveDB(s.path)
	if err != nil {
		return rollback(fmt.Errorf("open restored database: %w", err), nil)
	}
	if err := migrateDB(newDB); err != nil {
		return rollback(fmt.Errorf("migrate restored database: %w", err), newDB)
	}

	var counts RestoreCounts
	if err := newDB.QueryRow(`SELECT COUNT(*) FROM decks`).Scan(&counts.Decks); err != nil {
		return rollback(fmt.Errorf("count restored decks: %w", err), newDB)
	}
	if err := newDB.QueryRow(`SELECT COUNT(*) FROM cards`).Scan(&counts.Cards); err != nil {
		return rollback(fmt.Errorf("count restored cards: %w", err), newDB)
	}

	s.db = newDB
	if hasOriginal {
		_ = os.Remove(bakPath)
	}
	return counts, nil
}

func openLiveDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite3", sqliteDSN(path))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

func writeFileSync(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

func validateBackupBytes(data []byte) error {
	if len(data) < 100 || !bytes.HasPrefix(data, sqliteMagicHeader) {
		return fmt.Errorf("%w: file is not a valid SQLite 3 database", ErrValidation)
	}

	tmpDir, err := os.MkdirTemp("", "lunar-restore-check-*")
	if err != nil {
		return fmt.Errorf("create restore validation dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	candidatePath := filepath.Join(tmpDir, "candidate.db")
	if err := os.WriteFile(candidatePath, data, 0o600); err != nil {
		return fmt.Errorf("write validation db: %w", err)
	}

	valDB, err := sql.Open("sqlite3", candidatePath+"?_busy_timeout=5000")
	if err != nil {
		return fmt.Errorf("%w: unable to open SQLite file", ErrValidation)
	}
	valDB.SetMaxOpenConns(1)
	defer valDB.Close()

	rows, err := valDB.Query(`PRAGMA quick_check;`)
	if err != nil {
		return fmt.Errorf("%w: SQLite integrity check failed: %v", ErrValidation, err)
	}
	checked := false
	for rows.Next() {
		var status string
		if err := rows.Scan(&status); err != nil {
			_ = rows.Close()
			return fmt.Errorf("%w: SQLite integrity check failed: %v", ErrValidation, err)
		}
		checked = true
		if status != "ok" {
			_ = rows.Close()
			return fmt.Errorf("%w: SQLite integrity check returned %q", ErrValidation, status)
		}
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return fmt.Errorf("%w: SQLite integrity check failed: %v", ErrValidation, err)
	}
	_ = rows.Close()
	if !checked {
		return fmt.Errorf("%w: SQLite integrity check returned no result", ErrValidation)
	}

	requiredTables := map[string]bool{
		"decks":       false,
		"cards":       false,
		"review_logs": false,
	}
	tRows, err := valDB.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('decks', 'cards', 'review_logs')`)
	if err != nil {
		return fmt.Errorf("%w: inspect tables failed: %v", ErrValidation, err)
	}
	for tRows.Next() {
		var name string
		if err := tRows.Scan(&name); err != nil {
			_ = tRows.Close()
			return fmt.Errorf("%w: inspect tables failed: %v", ErrValidation, err)
		}
		requiredTables[name] = true
	}
	if err := tRows.Err(); err != nil {
		_ = tRows.Close()
		return fmt.Errorf("%w: inspect tables failed: %v", ErrValidation, err)
	}
	_ = tRows.Close()

	for table, found := range requiredTables {
		if !found {
			return fmt.Errorf("%w: missing required Lunar table %q", ErrValidation, table)
		}
	}

	schemaProbes := []string{
		`SELECT id, title, category, difficulty FROM decks LIMIT 0`,
		`SELECT id, deck_id, front, back FROM cards LIMIT 0`,
		`SELECT id, card_id, timestamp, rating, interval_days FROM review_logs LIMIT 0`,
	}
	for _, probe := range schemaProbes {
		if _, err := valDB.Exec(probe); err != nil {
			return fmt.Errorf("%w: incompatible Lunar schema: %v", ErrValidation, err)
		}
	}

	return nil
}
