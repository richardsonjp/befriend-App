package friend

import (
	"time"

	"befriend/pkg/utils/astro"
)

type CreatePayload struct {
	UserID          string
	Name            string
	UserNickname    string
	BornAt          time.Time
	City            string   // optional
	CountryCode     string   // optional, ISO 3166-1 alpha-2
	Latitude        *float64 // optional; stored rounded to city level
	Longitude       *float64
	Timezone        string
	Chart           astro.Chart
	NextEvolutionAt time.Time
}
