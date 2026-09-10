// Package astro derives a friend's deterministic "birth chart" from its birth instant:
// Western sun sign, Chinese zodiac (animal, element, yin/yang) and the Nine Star Ki year star used
// as the feng shui element. Everything is computed from the sun's position, so results are stable
// across servers and time zones.
package astro

import (
	"math"
	"time"
)

// Chart is the astrology input for personality generation.
type Chart struct {
	WesternSign     string `json:"western_sign"`
	ChineseAnimal   string `json:"chinese_animal"`
	ChineseElement  string `json:"chinese_element"`
	ChinesePolarity string `json:"chinese_polarity"`
	FengShuiStar    int    `json:"feng_shui_star"`
	FengShuiElement string `json:"feng_shui_element"`
}

var (
	westernSigns = [12]string{
		"Aries", "Taurus", "Gemini", "Cancer", "Leo", "Virgo",
		"Libra", "Scorpio", "Sagittarius", "Capricorn", "Aquarius", "Pisces",
	}
	chineseAnimals = [12]string{
		"Rat", "Ox", "Tiger", "Rabbit", "Dragon", "Snake",
		"Horse", "Goat", "Monkey", "Rooster", "Dog", "Pig",
	}
	// Heavenly stems pair up into the five elements; even stems are yang.
	stemElements = [10]string{"Wood", "Wood", "Fire", "Fire", "Earth", "Earth", "Metal", "Metal", "Water", "Water"}
	// Nine Star Ki: star number -> element (index 0 unused).
	starElements = [10]string{"", "Water", "Earth", "Wood", "Wood", "Earth", "Metal", "Metal", "Earth", "Fire"}
)

// lichunLongitude is the sun's apparent longitude at Lichun ("start of spring"), where the Chinese
// solar year and the Nine Star Ki year both begin.
const lichunLongitude = 315.0

// ChartAt computes the chart for a birth instant.
func ChartAt(t time.Time) Chart {
	lon := sunLongitude(t)
	year := solarYear(t, lon)
	stem := mod(year-4, 10)
	star := 9 - mod(year-2000, 9)

	polarity := "Yang"
	if stem%2 == 1 {
		polarity = "Yin"
	}

	return Chart{
		WesternSign:     westernSigns[int(lon/30)%12],
		ChineseAnimal:   chineseAnimals[mod(year-4, 12)],
		ChineseElement:  stemElements[stem],
		ChinesePolarity: polarity,
		FengShuiStar:    star,
		FengShuiElement: starElements[star],
	}
}

// solarYear is the Gregorian year whose Lichun most recently passed. Early in January and February,
// before the sun reaches 315°, the solar year is still the previous one.
func solarYear(t time.Time, lon float64) int {
	u := t.UTC()
	if u.Month() <= time.February && lon >= 270 && lon < lichunLongitude {
		return u.Year() - 1
	}
	return u.Year()
}

// sunLongitude returns the sun's apparent ecliptic longitude in degrees [0, 360), using the
// low-precision algorithm from Meeus, Astronomical Algorithms ch. 25 (accurate to ~0.01°, about 15 minutes).
func sunLongitude(t time.Time) float64 {
	jd := float64(t.UTC().UnixNano())/float64(24*time.Hour) + 2440587.5
	T := (jd - 2451545.0) / 36525

	L0 := 280.46646 + 36000.76983*T + 0.0003032*T*T
	M := rad(357.52911 + 35999.05029*T - 0.0001537*T*T)
	C := (1.914602-0.004817*T-0.000014*T*T)*math.Sin(M) +
		(0.019993-0.000101*T)*math.Sin(2*M) +
		0.000289*math.Sin(3*M)
	omega := rad(125.04 - 1934.136*T)
	apparent := L0 + C - 0.00569 - 0.00478*math.Sin(omega)

	return math.Mod(math.Mod(apparent, 360)+360, 360)
}

func rad(deg float64) float64 { return deg * math.Pi / 180 }

// mod is a modulo that stays non-negative for negative inputs.
func mod(a, n int) int { return ((a % n) + n) % n }
