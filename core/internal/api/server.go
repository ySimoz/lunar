// Package api exposes the localhost HTTP JSON REST API for lunar-core.
package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/mattn/go-sqlite3"

	"lunar/core/internal/domain"
	"lunar/core/internal/store"
)

const maxRequestBodyBytes = 1 << 20 // 1 MiB

// Server wraps the SQLite store behind a Go 1.22+ net/http ServeMux.
type Server struct {
	store *store.Store
	mux   *http.ServeMux
}

// NewServer creates an HTTP API server backed by s and registers all routes.
func NewServer(s *store.Store) *Server {
	srv := &Server{store: s, mux: http.NewServeMux()}
	srv.registerRoutes()
	return srv
}

// Handler returns the root http.Handler for the API server.
func (s *Server) Handler() http.Handler {
	return s.mux
}

func (s *Server) registerRoutes() {
	s.mux.HandleFunc("GET /health", s.handleHealth)

	s.mux.HandleFunc("GET /api/decks", s.handleListDecks)
	s.mux.HandleFunc("POST /api/decks", s.handleCreateDeck)
	s.mux.HandleFunc("POST /api/decks/reorder", s.handleReorderDecks)
	s.mux.HandleFunc("PUT /api/decks/{id}", s.handleUpdateDeck)
	s.mux.HandleFunc("DELETE /api/decks/{id}", s.handleDeleteDeck)
	s.mux.HandleFunc("GET /api/decks/{id}/cards", s.handleListDeckCards)
	s.mux.HandleFunc("GET /api/decks/{id}/export", s.handleExportDeck)
	s.mux.HandleFunc("POST /api/decks/{id}/reorder", s.handleReorderCards)
	s.mux.HandleFunc("POST /api/import", s.handleImportDeck)

	s.mux.HandleFunc("GET /api/cards", s.handleListCards)
	s.mux.HandleFunc("POST /api/cards", s.handleCreateCard)
	s.mux.HandleFunc("POST /api/cards/transfer", s.handleTransferCards)
	s.mux.HandleFunc("PUT /api/cards/{id}", s.handleUpdateCard)
	s.mux.HandleFunc("DELETE /api/cards/{id}", s.handleDeleteCard)
	s.mux.HandleFunc("POST /api/cards/{id}/review", s.handleReviewCard)
	s.mux.HandleFunc("GET /api/cards/{id}/predict", s.handlePredictCard)

	s.mux.HandleFunc("GET /api/sessions", s.handleListSessions)
	s.mux.HandleFunc("POST /api/sessions", s.handleCreateSession)

	s.mux.HandleFunc("GET /api/active-session", s.handleGetActiveSession)
	s.mux.HandleFunc("PUT /api/active-session", s.handleSaveActiveSession)
	s.mux.HandleFunc("DELETE /api/active-session", s.handleClearActiveSession)

	s.mux.HandleFunc("GET /api/preferences", s.handleGetPreferences)
	s.mux.HandleFunc("PUT /api/preferences", s.handleUpdatePreferences)

	s.mux.HandleFunc("GET /api/stats", s.handleGetStats)
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleListDecks(w http.ResponseWriter, _ *http.Request) {
	decks, err := s.store.ListDecks(time.Now())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, decks)
}

func (s *Server) handleCreateDeck(w http.ResponseWriter, r *http.Request) {
	var deck domain.Deck
	if err := decodeJSON(w, r, &deck); err != nil {
		writeDecodeError(w, err)
		return
	}
	created, err := s.store.CreateDeck(deck)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, created)
}

func (s *Server) handleUpdateDeck(w http.ResponseWriter, r *http.Request) {
	var deck domain.Deck
	if err := decodeJSON(w, r, &deck); err != nil {
		writeDecodeError(w, err)
		return
	}
	updated, err := s.store.UpdateDeck(r.PathValue("id"), deck)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, updated)
}

func (s *Server) handleDeleteDeck(w http.ResponseWriter, r *http.Request) {
	if err := s.store.DeleteDeck(r.PathValue("id")); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleReorderDecks(w http.ResponseWriter, r *http.Request) {
	var body struct {
		DeckIDs []string `json:"deckIds"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		writeDecodeError(w, err)
		return
	}
	if err := s.store.ReorderDecks(body.DeckIDs); err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"reordered": true})
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(dst); err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			return err
		}
		return errors.New("invalid JSON request body")
	}
	var trailing any
	if err := dec.Decode(&trailing); err != io.EOF {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			return err
		}
		return errors.New("invalid JSON request body")
	}
	return nil
}

func writeDecodeError(w http.ResponseWriter, err error) {
	var maxBytesErr *http.MaxBytesError
	if errors.As(err, &maxBytesErr) {
		writeError(w, http.StatusRequestEntityTooLarge, "request body too large")
		return
	}
	writeError(w, http.StatusBadRequest, err.Error())
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func isUniqueConstraintError(err error) bool {
	var sqliteErr sqlite3.Error
	if !errors.As(err, &sqliteErr) {
		return false
	}
	return sqliteErr.ExtendedCode == sqlite3.ErrConstraintUnique ||
		sqliteErr.ExtendedCode == sqlite3.ErrConstraintPrimaryKey
}

func writeStoreError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, store.ErrValidation):
		writeError(w, http.StatusBadRequest, err.Error())
	case isUniqueConstraintError(err):
		writeError(w, http.StatusConflict, "record already exists")
	default:
		writeError(w, http.StatusInternalServerError, "internal server error")
	}
}
