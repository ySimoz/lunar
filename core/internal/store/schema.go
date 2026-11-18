package store

const schemaSQL = `
CREATE TABLE IF NOT EXISTS decks (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL DEFAULT 'default',
	title TEXT NOT NULL,
	description TEXT NOT NULL DEFAULT '',
	category TEXT NOT NULL,
	difficulty TEXT NOT NULL,
	color TEXT NOT NULL DEFAULT 'indigo',
	chapters_json TEXT NOT NULL DEFAULT '[]',
	deck_order INTEGER NOT NULL DEFAULT 0,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS cards (
	id TEXT PRIMARY KEY,
	deck_id TEXT NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL DEFAULT 'default',
	topic TEXT NOT NULL DEFAULT '',
	card_order INTEGER NOT NULL DEFAULT 0,
	card_type TEXT NOT NULL DEFAULT '',
	front TEXT NOT NULL,
	back TEXT NOT NULL,
	explanation TEXT NOT NULL DEFAULT '',
	difficulty TEXT NOT NULL,
	tags_json TEXT NOT NULL DEFAULT '[]',
	repetition INTEGER NOT NULL DEFAULT 0,
	interval_days INTEGER NOT NULL DEFAULT 1,
	ease_factor REAL NOT NULL DEFAULT 2.5,
	next_review_date TEXT NOT NULL,
	last_reviewed TEXT NOT NULL DEFAULT '',
	total_reviews INTEGER NOT NULL DEFAULT 0,
	correct_count INTEGER NOT NULL DEFAULT 0,
	incorrect_count INTEGER NOT NULL DEFAULT 0,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cards_deck_id ON cards(deck_id, card_order);

CREATE TABLE IF NOT EXISTS card_layers (
	id TEXT PRIMARY KEY,
	card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
	position INTEGER NOT NULL,
	title TEXT NOT NULL,
	content TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_card_layers_card_id ON card_layers(card_id, position);

CREATE TABLE IF NOT EXISTS review_logs (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
	timestamp TEXT NOT NULL,
	rating INTEGER NOT NULL,
	interval_days INTEGER NOT NULL,
	duration_ms INTEGER,
	prev_state TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_review_logs_card_id ON review_logs(card_id, id);

CREATE TABLE IF NOT EXISTS study_sessions (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL DEFAULT 'default',
	mode TEXT NOT NULL,
	deck_ids_json TEXT NOT NULL DEFAULT '[]',
	deck_titles_json TEXT NOT NULL DEFAULT '[]',
	cards_reviewed INTEGER NOT NULL,
	correct_count INTEGER NOT NULL,
	incorrect_count INTEGER NOT NULL,
	lives_left INTEGER,
	duration_seconds INTEGER NOT NULL,
	completed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS active_session (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	session_id TEXT NOT NULL,
	deck_id TEXT NOT NULL DEFAULT '',
	deck_ids_json TEXT NOT NULL DEFAULT '[]',
	mode TEXT NOT NULL,
	current_index INTEGER NOT NULL,
	card_ids_json TEXT NOT NULL DEFAULT '[]',
	reviewed_card_ids_json TEXT NOT NULL DEFAULT '[]',
	correct_count INTEGER NOT NULL,
	incorrect_count INTEGER NOT NULL,
	lives_left INTEGER,
	started_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS preferences (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	font_family TEXT NOT NULL,
	font_size TEXT NOT NULL,
	retro_ui_font TEXT NOT NULL,
	theme TEXT NOT NULL,
	color_mode TEXT NOT NULL,
	sound_enabled INTEGER NOT NULL,
	default_lives INTEGER NOT NULL,
	auto_reveal_steps INTEGER NOT NULL,
	show_helper_descriptions INTEGER NOT NULL,
	clock_style TEXT NOT NULL
);
`
