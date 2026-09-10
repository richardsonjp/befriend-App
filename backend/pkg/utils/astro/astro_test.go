package astro

import (
	"testing"
	"time"
)

func utc(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

// Equinox/solstice instants (UTC) from published ephemerides; checked 2h either side.
func TestWesternSignAtSeasonBoundaries(t *testing.T) {
	tests := []struct {
		name          string
		boundary      string
		before, after string
	}{
		{"March equinox 2024", "2024-03-20T03:06:00Z", "Pisces", "Aries"},
		{"March equinox 2025", "2025-03-20T09:01:00Z", "Pisces", "Aries"},
		{"March equinox 2026", "2026-03-20T14:46:00Z", "Pisces", "Aries"},
		{"June solstice 2024", "2024-06-20T20:51:00Z", "Gemini", "Cancer"},
		{"December solstice 2024", "2024-12-21T09:20:00Z", "Sagittarius", "Capricorn"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b := utc(tt.boundary)
			if got := ChartAt(b.Add(-2 * time.Hour)).WesternSign; got != tt.before {
				t.Errorf("2h before: %s, want %s", got, tt.before)
			}
			if got := ChartAt(b.Add(2 * time.Hour)).WesternSign; got != tt.after {
				t.Errorf("2h after: %s, want %s", got, tt.after)
			}
		})
	}
}

func TestChineseYearAndNineStarKi(t *testing.T) {
	tests := []struct {
		name string
		at   string
		want Chart
	}{
		{"mid 2024: Wood Dragon, 3 Wood", "2024-07-01T00:00:00Z",
			Chart{"Cancer", "Dragon", "Wood", "Yang", 3, "Wood"}},
		{"mid 2025: Wood Snake, 2 Earth", "2025-07-01T00:00:00Z",
			Chart{"Cancer", "Snake", "Wood", "Yin", 2, "Earth"}},
		{"mid 2026: Fire Horse, 1 Water", "2026-07-01T00:00:00Z",
			Chart{"Cancer", "Horse", "Fire", "Yang", 1, "Water"}},
		{"mid 2000: Metal Dragon, 9 Fire", "2000-07-01T00:00:00Z",
			Chart{"Cancer", "Dragon", "Metal", "Yang", 9, "Fire"}},
		{"mid 1999: Earth Rabbit, 1 Water", "1999-07-01T00:00:00Z",
			Chart{"Cancer", "Rabbit", "Earth", "Yin", 1, "Water"}},
		// Before Lichun the previous solar year still applies (Lichun 2025 is Feb 3 in UTC).
		{"Jan 2025 is still the Dragon year", "2025-01-15T00:00:00Z",
			Chart{"Capricorn", "Dragon", "Wood", "Yang", 3, "Wood"}},
		{"Feb 2 2025 is still the Dragon year", "2025-02-02T12:00:00Z",
			Chart{"Aquarius", "Dragon", "Wood", "Yang", 3, "Wood"}},
		{"Feb 4 2025 is the Snake year", "2025-02-04T12:00:00Z",
			Chart{"Aquarius", "Snake", "Wood", "Yin", 2, "Earth"}},
		{"late December stays in the same year", "2024-12-31T00:00:00Z",
			Chart{"Capricorn", "Dragon", "Wood", "Yang", 3, "Wood"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ChartAt(utc(tt.at)); got != tt.want {
				t.Fatalf("ChartAt(%s)\n got  %+v\n want %+v", tt.at, got, tt.want)
			}
		})
	}
}

// Lichun must fall on Feb 3–5 (UTC) every year; this catches a broken longitude formula or year rule.
func TestLichunFallsInEarlyFebruary(t *testing.T) {
	for year := 1950; year <= 2100; year++ {
		start := time.Date(year, time.February, 3, 0, 0, 0, 0, time.UTC)
		end := time.Date(year, time.February, 6, 0, 0, 0, 0, time.UTC)
		if sunLongitude(start) >= lichunLongitude {
			t.Fatalf("%d: sun already past 315° on Feb 3", year)
		}
		if sunLongitude(end) < lichunLongitude {
			t.Fatalf("%d: sun not yet at 315° by Feb 6", year)
		}
		if ChartAt(start).ChineseAnimal == ChartAt(end).ChineseAnimal {
			t.Fatalf("%d: animal did not change across Lichun", year)
		}
	}
}
