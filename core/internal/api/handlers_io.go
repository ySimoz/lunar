package api

import (
	"errors"
	"net/http"
	"time"

	"lunar/core/internal/domain"
	lunario "lunar/core/internal/io"
)

func (s *Server) handleExportDeck(w http.ResponseWriter, r *http.Request) {
	deckID := r.PathValue("id")
	rawFormat := r.URL.Query().Get("format")
	if rawFormat == "" {
		rawFormat = "json"
	}
	format, err := lunario.ParseFormat(rawFormat)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	deck, err := s.store.GetDeck(deckID, time.Now())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	cards, err := s.store.ListCards(deckID)
	if err != nil {
		writeStoreError(w, err)
		return
	}

	res, err := lunario.ExportDeck(deck, cards, format)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) handleImportDeck(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Format       string                 `json:"format"`
		Content      string                 `json:"content"`
		TargetDeckID string                 `json:"targetDeckId"`
		NewDeckTitle string                 `json:"newDeckTitle"`
		Category     domain.SubjectCategory `json:"category"`
		TargetTopic  string                 `json:"targetTopic"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeDecodeError(w, err)
		return
	}
	if req.Category != "" && !req.Category.IsValid() {
		writeError(w, http.StatusBadRequest, "invalid deck category")
		return
	}
	format, err := lunario.ParseFormat(req.Format)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	parsed, err := lunario.Import(format, req.Content, lunario.ImportOptions{
		TargetDeckID: req.TargetDeckID,
		NewDeckTitle: req.NewDeckTitle,
		Category:     req.Category,
		TargetTopic:  req.TargetTopic,
	})
	if err != nil {
		if errors.Is(err, lunario.ErrInvalidImport) {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	deck, savedCards, err := s.store.BulkImport(req.TargetDeckID, parsed.Deck, parsed.Cards)
	if err != nil {
		writeStoreError(w, err)
		return
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"deck":          deck,
		"importedCount": len(savedCards),
		"cards":         savedCards,
	})
}
