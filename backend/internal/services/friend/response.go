package friend

import (
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
}

// Birthplace is deliberately coarse: coordinates stay server-side.
type Birthplace struct {
	City        string `json:"city,omitempty"`
	CountryCode string `json:"country_code,omitempty"`
}

type PersonalityState struct {
	Status  string `json:"status"` // pending | running | ready | failed
	Version int    `json:"version"`
}
