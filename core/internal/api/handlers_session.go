package api

import (
	"net/http"

	"lunar/core/internal/domain"
)

func (s *Server) handleListSessions(w http.ResponseWriter, _ *http.Request) {
	sessions, err := s.store.ListSessions()
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sessions)
}

func (s *Server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	var rec domain.StudySessionRecord
	if err := decodeJSON(w, r, &rec); err != nil {
		writeDecodeError(w, err)
		return
	}
	created, err := s.store.CreateSession(rec)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, created)
}

func (s *Server) handleGetActiveSession(w http.ResponseWriter, _ *http.Request) {
	st, err := s.store.GetActiveSession()
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) handleSaveActiveSession(w http.ResponseWriter, r *http.Request) {
	var st domain.ActiveSessionState
	if err := decodeJSON(w, r, &st); err != nil {
		writeDecodeError(w, err)
		return
	}
	saved, err := s.store.SaveActiveSession(st)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, saved)
}

func (s *Server) handleClearActiveSession(w http.ResponseWriter, _ *http.Request) {
	if err := s.store.ClearActiveSession(); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetPreferences(w http.ResponseWriter, _ *http.Request) {
	prefs, err := s.store.GetPreferences()
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, prefs)
}

func (s *Server) handleUpdatePreferences(w http.ResponseWriter, r *http.Request) {
	var prefs domain.UserPreferences
	if err := decodeJSON(w, r, &prefs); err != nil {
		writeDecodeError(w, err)
		return
	}
	updated, err := s.store.UpdatePreferences(prefs)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, updated)
}
