package friend

import (
	"encoding/json"
	"time"

	"befriend/pkg/utils/astro"
)

type ProfileResponse struct {
	Name         string           `json:"name"`
	UserNickname string           `json:"user_nickname"`
	BornAt       time.Time        `json:"born_at"`
	Birthplace   *Birthplace      `json:"birthplace,omitempty"`
	Timezone     string           `json:"timezone"`
	Chart        astro.Chart      `json:"chart"`
	Personality  PersonalityState `json:"personality"`
	// Phrasebook of the current ready version: [{trigger, mood, lines: [{text, action}]}]. A list, not a map:
	// mood names come from skins (under_scores allowed) and the apps' snake_case key decoding rewrites map keys.
	Phrasebook json.RawMessage `json:"phrasebook,omitempty"`
}

// Birthplace is deliberately coarse: coordinates stay server-side.
type Birthplace struct {
	City        string `json:"city,omitempty"`
	CountryCode string `json:"country_code,omitempty"`
}

// PersonalityState reports the latest version's progress; Content comes from the current ready version,
// which can be an older one while a newer version is still generating.
type PersonalityState struct {
	Status            string          `json:"status"` // pending | running | ready | failed
	Version           int             `json:"version"`
	VocabularyVersion int             `json:"vocabulary_version,omitempty"`
	Content           json.RawMessage `json:"content,omitempty"` // {summary, traits, voice, instructions}
}
