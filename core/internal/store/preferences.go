package store

import (
	"database/sql"
	"errors"
	"fmt"

	"lunar/core/internal/domain"
)

// GetPreferences returns persisted UserPreferences or defaults when none are saved yet.
func (s *Store) GetPreferences() (domain.UserPreferences, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	row := s.db.QueryRow(`
		SELECT font_family, font_size, retro_ui_font, theme, color_mode,
		       sound_enabled, default_lives, auto_reveal_steps,
		       show_helper_descriptions, clock_style
		FROM preferences WHERE id = 1`)

	var p domain.UserPreferences
	var sound, autoReveal, showHelper int
	err := row.Scan(
		&p.FontFamily, &p.FontSize, &p.RetroUIFont, &p.Theme, &p.ColorMode,
		&sound, &p.DefaultLives, &autoReveal, &showHelper, &p.ClockStyle,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.DefaultPreferences(), nil
	}
	if err != nil {
		return domain.UserPreferences{}, fmt.Errorf("query preferences: %w", err)
	}
	p.SoundEnabled = sound != 0
	p.AutoRevealSteps = autoReveal != 0
	p.ShowHelperDescriptions = showHelper != 0
	return p, nil
}

// UpdatePreferences validates and persists the singleton UserPreferences row (id = 1).
func (s *Store) UpdatePreferences(p domain.UserPreferences) (domain.UserPreferences, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	d := domain.DefaultPreferences()
	if p.Theme == "" {
		p.Theme = d.Theme
	}
	if p.RetroUIFont == "" {
		p.RetroUIFont = d.RetroUIFont
	}
	if p.ColorMode == "" {
		p.ColorMode = d.ColorMode
	}
	if p.ClockStyle == "" {
		p.ClockStyle = d.ClockStyle
	}
	if err := p.Validate(); err != nil {
		return domain.UserPreferences{}, fmt.Errorf("%w: %v", ErrValidation, err)
	}
	_, err := s.db.Exec(`
		INSERT INTO preferences (
			id, font_family, font_size, retro_ui_font, theme, color_mode,
			sound_enabled, default_lives, auto_reveal_steps,
			show_helper_descriptions, clock_style
		) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			font_family = excluded.font_family,
			font_size = excluded.font_size,
			retro_ui_font = excluded.retro_ui_font,
			theme = excluded.theme,
			color_mode = excluded.color_mode,
			sound_enabled = excluded.sound_enabled,
			default_lives = excluded.default_lives,
			auto_reveal_steps = excluded.auto_reveal_steps,
			show_helper_descriptions = excluded.show_helper_descriptions,
			clock_style = excluded.clock_style`,
		p.FontFamily, p.FontSize, p.RetroUIFont, p.Theme, p.ColorMode,
		boolToInt(p.SoundEnabled), p.DefaultLives, boolToInt(p.AutoRevealSteps),
		boolToInt(p.ShowHelperDescriptions), p.ClockStyle,
	)
	if err != nil {
		return domain.UserPreferences{}, fmt.Errorf("update preferences: %w", err)
	}
	return p, nil
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
