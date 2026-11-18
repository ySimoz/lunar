package api

import (
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
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

func (s *Server) handleImportAPKG(w http.ResponseWriter, r *http.Request) {
	data, err := readUploadBody(w, r)
	if err != nil {
		writeUploadReadError(w, err)
		return
	}

	q := r.URL.Query()
	deckID := strings.TrimSpace(q.Get("deck_id"))
	deckName := strings.TrimSpace(q.Get("deck_name"))
	skipDupRaw := strings.ToLower(strings.TrimSpace(q.Get("skip_duplicates")))
	skipDuplicates := skipDupRaw == "true" || skipDupRaw == "1" || skipDupRaw == "yes"

	var existingDeck domain.Deck
	if deckID != "" {
		existingDeck, err = s.store.GetDeck(deckID, time.Now())
		if err != nil {
			writeStoreError(w, err)
			return
		}
	}

	parsed, err := lunario.ImportAPKG(data, lunario.ImportOptions{
		TargetDeckID: deckID,
		NewDeckTitle: deckName,
	})
	if err != nil {
		if errors.Is(err, lunario.ErrInvalidImport) {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	cardsToImport := parsed.Cards
	if skipDuplicates {
		seen := make(map[string]struct{}, len(cardsToImport))
		if deckID != "" {
			existingCards, err := s.store.ListCards(deckID)
			if err != nil {
				writeStoreError(w, err)
				return
			}
			for _, c := range existingCards {
				seen[apkgDuplicateKey(c.Front, c.Back)] = struct{}{}
			}
		}
		filtered := make([]domain.Flashcard, 0, len(cardsToImport))
		for _, c := range cardsToImport {
			key := apkgDuplicateKey(c.Front, c.Back)
			if _, dup := seen[key]; dup {
				continue
			}
			seen[key] = struct{}{}
			filtered = append(filtered, c)
		}
		cardsToImport = filtered
	}

	if len(cardsToImport) == 0 && deckID != "" {
		writeJSON(w, http.StatusOK, map[string]any{
			"deck":          existingDeck,
			"importedCount": 0,
			"cards":         []domain.Flashcard{},
		})
		return
	}

	deck, savedCards, err := s.store.BulkImport(deckID, parsed.Deck, cardsToImport)
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

func (s *Server) handleBackup(w http.ResponseWriter, _ *http.Request) {
	data, err := s.store.Backup()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", `attachment; filename="lunar-backup.db"`)
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (s *Server) handleRestore(w http.ResponseWriter, r *http.Request) {
	data, err := readUploadBody(w, r)
	if err != nil {
		writeUploadReadError(w, err)
		return
	}
	counts, err := s.store.Restore(data)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, counts)
}

func readUploadBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBodyBytes)
	return io.ReadAll(r.Body)
}

func writeUploadReadError(w http.ResponseWriter, err error) {
	var maxBytesErr *http.MaxBytesError
	if errors.As(err, &maxBytesErr) {
		writeError(w, http.StatusRequestEntityTooLarge, "request body too large")
		return
	}
	writeError(w, http.StatusBadRequest, "failed to read request body")
}

func apkgDuplicateKey(front, back string) string {
	return strings.TrimSpace(front) + "\x00" + strings.TrimSpace(back)
}
