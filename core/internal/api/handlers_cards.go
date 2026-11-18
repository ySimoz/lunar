package api

import (
	"net/http"
	"strconv"
	"time"

	"lunar/core/internal/domain"
	"lunar/core/internal/srs"
)

func (s *Server) handleListDeckCards(w http.ResponseWriter, r *http.Request) {
	deckID := r.PathValue("id")
	if _, err := s.store.GetDeck(deckID, time.Now()); err != nil {
		writeStoreError(w, err)
		return
	}
	cards, err := s.store.ListCards(deckID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, cards)
}

func (s *Server) handleListCards(w http.ResponseWriter, r *http.Request) {
	deckID := r.URL.Query().Get("deckId")
	cards, err := s.store.ListCards(deckID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, cards)
}

func (s *Server) handleCreateCard(w http.ResponseWriter, r *http.Request) {
	var card domain.Flashcard
	if err := decodeJSON(w, r, &card); err != nil {
		writeDecodeError(w, err)
		return
	}
	created, err := s.store.CreateCard(card)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, created)
}

func (s *Server) handleUpdateCard(w http.ResponseWriter, r *http.Request) {
	var card domain.Flashcard
	if err := decodeJSON(w, r, &card); err != nil {
		writeDecodeError(w, err)
		return
	}
	updated, err := s.store.UpdateCardContent(r.PathValue("id"), card)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, updated)
}

func (s *Server) handleDeleteCard(w http.ResponseWriter, r *http.Request) {
	if err := s.store.DeleteCard(r.PathValue("id")); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleReorderCards(w http.ResponseWriter, r *http.Request) {
	var body struct {
		CardIDs []string `json:"cardIds"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		writeDecodeError(w, err)
		return
	}
	if err := s.store.ReorderCards(r.PathValue("id"), body.CardIDs); err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"reordered": true})
}

func (s *Server) handleReviewCard(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Rating     int    `json:"rating"`
		DurationMs *int64 `json:"durationMs"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		writeDecodeError(w, err)
		return
	}
	updated, err := s.store.ReviewCard(r.PathValue("id"), body.Rating, body.DurationMs, time.Now())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, updated)
}

func (s *Server) handleUndoCardReview(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ReviewLogID *int64 `json:"reviewLogId"`
	}
	if err := decodeOptionalJSON(w, r, &body); err != nil {
		writeDecodeError(w, err)
		return
	}
	restored, err := s.store.UndoCardReview(r.PathValue("id"), body.ReviewLogID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, restored)
}

func (s *Server) handlePredictCard(w http.ResponseWriter, r *http.Request) {
	card, err := s.store.GetCard(r.PathValue("id"))
	if err != nil {
		writeStoreError(w, err)
		return
	}
	predictions := make(map[string]srs.IntervalPrediction, 4)
	for q := 1; q <= 4; q++ {
		pred, err := srs.PredictInterval(card, q)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
		predictions[strconv.Itoa(q)] = pred
	}
	writeJSON(w, http.StatusOK, predictions)
}

func (s *Server) handleTransferCards(w http.ResponseWriter, r *http.Request) {
	var req domain.TransferCardsRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeDecodeError(w, err)
		return
	}
	moved, err := s.store.TransferCards(r.Context(), req)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"moved": moved})
}
