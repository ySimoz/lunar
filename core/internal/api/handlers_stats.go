package api

import (
	"net/http"
	"strconv"
	"time"
)

func (s *Server) handleGetStats(w http.ResponseWriter, r *http.Request) {
	days := 30
	if rawDays := r.URL.Query().Get("days"); rawDays != "" {
		parsed, err := strconv.Atoi(rawDays)
		if err != nil || parsed < 1 || parsed > 365 {
			writeError(w, http.StatusBadRequest, "days must be an integer between 1 and 365")
			return
		}
		days = parsed
	}

	summary, err := s.store.GetStats(days, time.Now())
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, summary)
}
