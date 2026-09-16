package personality

import (
	"fmt"
	"math/rand/v2"
	"strings"
	"time"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/pkg/utils/astro"
)

// Synthetic users for harvesting training data (M8). The fine-tune is distilled from Apple's on-device model
// running on the developer's Mac, which needs something to answer questions about — and the questionnaire is a
// finite space, so no LLM is needed to invent one. Question set v1 alone has 4x4x10x4x5x4x4x10 = 512,000 answer
// combinations before names and birth charts, which is far more than a harvest will ever use.
//
// The point is coverage, not realism: the fine-tune must see every option of every question, or it will learn to
// ignore the ones it never saw.

// Harvest name pools. Short and plain on purpose — the friend's name is used verbatim in its instructions, so
// anything odd here becomes noise the student has to model.
var (
	friendNames = []string{
		"Miso", "Pixel", "Tofu", "Biscuit", "Nori", "Comma", "Pepper", "Waffle", "Mochi", "Sprout",
		"Bean", "Domino", "Olive", "Pumpkin", "Scout", "Sesame", "Clover", "Marble", "Noodle", "Ziggy",
	}
	userNicknames = []string{
		"Ricky", "Sam", "Alex", "Jo", "Kim", "Ren", "Toni", "Mo", "Wren", "Dee",
		"Nik", "Cass", "Rue", "Ari", "Bo", "Lee", "Max", "Nia", "Ky", "Sol",
	}
	birthplaces = []struct{ City, Country string }{
		{"Jakarta", "ID"}, {"Surabaya", "ID"}, {"Bandung", "ID"}, {"Singapore", "SG"}, {"Kuala Lumpur", "MY"},
		{"Tokyo", "JP"}, {"Seoul", "KR"}, {"Taipei", "TW"}, {"Manila", "PH"}, {"Bangkok", "TH"},
		{"Sydney", "AU"}, {"London", "GB"}, {"Berlin", "DE"}, {"Amsterdam", "NL"}, {"Toronto", "CA"},
		{"New York", "US"}, {"San Francisco", "US"}, {"Austin", "US"}, {"São Paulo", "BR"}, {"Lisbon", "PT"},
	}
)

// harvestBirthRange is the window synthetic birth moments are drawn from, wide enough to cover every western
// sign, chinese animal and feng shui star.
var harvestBirthRange = struct{ From, To time.Time }{
	From: time.Date(1990, 1, 1, 0, 0, 0, 0, time.UTC),
	To:   time.Date(2010, 1, 1, 0, 0, 0, 0, time.UTC),
}

// HarvestInputs builds n distinct synthetic users from a question set. The same seed always gives the same
// inputs, so a harvest can be resumed or extended without regenerating what the Mac already answered.
func HarvestInputs(questions []model.Question, n int, seed uint64) ([]PromptInput, error) {
	if n <= 0 {
		return nil, fmt.Errorf("want at least one input, got %d", n)
	}
	if len(questions) == 0 {
		return nil, fmt.Errorf("the question set is empty")
	}
	random := rand.New(rand.NewPCG(seed, 0x9E3779B97F4A7C15))

	inputs := make([]PromptInput, 0, n)
	seen := make(map[string]bool, n)
	// Distinct inputs are drawn by rejection. The space dwarfs any plausible n, so a long run of nothing but
	// duplicates means the space really is exhausted, not that we were unlucky — give up on that rather than
	// on a multiple of n, which would grind for minutes before saying so.
	const giveUpAfter = 1000
	for misses := 0; len(inputs) < n; {
		in := harvestInput(questions, random)
		key := harvestKey(in)
		if seen[key] {
			if misses++; misses >= giveUpAfter {
				return nil, fmt.Errorf("only %d distinct inputs available out of %d wanted; is the question set this small?", len(inputs), n)
			}
			continue
		}
		seen[key] = true
		misses = 0
		inputs = append(inputs, in)
	}
	return inputs, nil
}

func harvestInput(questions []model.Question, random *rand.Rand) PromptInput {
	name := friendNames[random.IntN(len(friendNames))]
	nickname := userNicknames[random.IntN(len(userNicknames))]

	answers := make([]AnsweredQuestion, 0, len(questions))
	for _, q := range questions {
		answers = append(answers, AnsweredQuestion{Question: q.Prompt, Answer: harvestAnswer(q, name, nickname, random)})
	}

	where := birthplaces[random.IntN(len(birthplaces))]
	span := harvestBirthRange.To.Sub(harvestBirthRange.From)
	born := harvestBirthRange.From.Add(time.Duration(random.Int64N(int64(span))))

	return PromptInput{
		FriendName:   name,
		UserNickname: nickname,
		Answers:      answers,
		Chart:        astro.ChartAt(born),
		BirthCity:    where.City,
		BirthCountry: where.Country,
	}
}

// harvestAnswer answers one question the way the app would. The two text questions are the friend's name and
// what it calls the user, which PromptInput also carries at the top level, so they are filled from the same pair.
func harvestAnswer(q model.Question, name, nickname string, random *rand.Rand) interface{} {
	switch q.Type {
	case enum.QUESTION_CHOICE:
		if len(q.Options) == 0 {
			return ""
		}
		return q.Options[random.IntN(len(q.Options))]
	case enum.QUESTION_SLIDER:
		if q.Max <= q.Min {
			return q.Min
		}
		return q.Min + random.IntN(q.Max-q.Min+1)
	case enum.QUESTION_TEXT:
		if strings.Contains(q.ID, "nickname") || strings.Contains(q.ID, "user") {
			return nickname
		}
		return name
	default:
		return ""
	}
}

func harvestKey(in PromptInput) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s|%s|%s", in.FriendName, in.UserNickname, in.Chart.WesternSign)
	for _, a := range in.Answers {
		fmt.Fprintf(&b, "|%v", a.Answer)
	}
	return b.String()
}
