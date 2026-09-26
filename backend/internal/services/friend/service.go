package friend

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"math"
	"slices"
	"strings"
	"time"

	"befriend/internal/model"
	"befriend/pkg/utils/astro"
)

func (s *friendService) Create(ctx context.Context, payload CreatePayload) (*model.Friend, error) {
	m := &model.Friend{
		UserID:          payload.UserID,
		Name:            payload.Name,
		UserNickname:    payload.UserNickname,
		BornAt:          payload.BornAt,
		BirthLat:        cityLevel(payload.Latitude),
		BirthLon:        cityLevel(payload.Longitude),
		BirthTZ:         payload.Timezone,
		WesternSign:     payload.Chart.WesternSign,
		ChineseAnimal:   payload.Chart.ChineseAnimal,
		ChineseElement:  payload.Chart.ChineseElement,
		ChinesePolarity: payload.Chart.ChinesePolarity,
		FengShuiStar:    payload.Chart.FengShuiStar,
		FengShuiElement: payload.Chart.FengShuiElement,
		NextEvolutionAt: payload.NextEvolutionAt,
	}
	if payload.City != "" {
		city := payload.City
		m.BirthCity = &city
	}
	if payload.CountryCode != "" {
		country := strings.ToUpper(payload.CountryCode)
		m.BirthCountry = &country
	}
	return s.friendRepo.Create(ctx, m)
}

func (s *friendService) GetByID(ctx context.Context, id string) (*model.Friend, error) {
	return s.friendRepo.GetByID(ctx, id)
}

func (s *friendService) GetByUserID(ctx context.Context, userID string) (*model.Friend, error) {
	return s.friendRepo.GetByUserID(ctx, userID)
}

func (s *friendService) SetCurrentVersion(ctx context.Context, friendID, versionID string) error {
	return s.friendRepo.SetCurrentVersion(ctx, friendID, versionID)
}

func (s *friendService) ListDueForEvolution(ctx context.Context, now time.Time, limit int) ([]model.Friend, error) {
	return s.friendRepo.ListDueForEvolution(ctx, now, limit)
}

func (s *friendService) SetNextEvolutionAt(ctx context.Context, friendID string, next time.Time) error {
	return s.friendRepo.SetNextEvolutionAt(ctx, friendID, next)
}

// GetProfile is the friend as the apps see it: the current version once one is ready (a queued evolution or
// reskin doesn't send the apps back to hatching), else the latest version's status.
func (s *friendService) GetProfile(ctx context.Context, userID string) (*ProfileResponse, error) {
	f, err := s.friendRepo.GetByUserID(ctx, userID)
	if err != nil {
		return nil, err
	}
	latest, err := s.personalityVersionService.GetLatestByFriend(ctx, f.ID)
	if err != nil {
		return nil, err
	}

	profile := &ProfileResponse{
		Name:         f.Name,
		UserNickname: f.UserNickname,
		BornAt:       f.BornAt,
		Timezone:     f.BirthTZ,
		Chart: astro.Chart{
			WesternSign:     f.WesternSign,
			ChineseAnimal:   f.ChineseAnimal,
			ChineseElement:  f.ChineseElement,
			ChinesePolarity: f.ChinesePolarity,
			FengShuiStar:    f.FengShuiStar,
			FengShuiElement: f.FengShuiElement,
		},
		Personality: PersonalityState{Status: latest.Status.String(), Version: latest.Version},
	}
	if f.BirthCity != nil || f.BirthCountry != nil {
		profile.Birthplace = &Birthplace{}
		if f.BirthCity != nil {
			profile.Birthplace.City = *f.BirthCity
		}
		if f.BirthCountry != nil {
			profile.Birthplace.CountryCode = *f.BirthCountry
		}
	}

	if f.CurrentVersionID != nil {
		current, err := s.personalityVersionService.GetByID(ctx, *f.CurrentVersionID)
		if err != nil {
			return nil, err
		}
		if current.Personality != nil && current.Phrasebook != nil {
			profile.Personality.Content = current.Personality.Data
			if profile.Phrasebook, err = phrasebookEntries(current.Phrasebook.Data); err != nil {
				return nil, err
			}
		}
		profile.Personality.Status = current.Status.String()
		profile.Personality.Version = current.Version
		if current.VocabularyVersion != nil {
			profile.Personality.VocabularyVersion = *current.VocabularyVersion
		}
	}
	return profile, nil
}

// phrasebookEntries turns the stored phrasebook[trigger][mood] into the list the apps read, in a stable order.
func phrasebookEntries(stored json.RawMessage) (json.RawMessage, error) {
	var book map[string]map[string]json.RawMessage
	if err := json.Unmarshal(stored, &book); err != nil {
		return nil, fmt.Errorf("stored phrasebook: %w", err)
	}
	type entry struct {
		Trigger string          `json:"trigger"`
		Mood    string          `json:"mood"`
		Lines   json.RawMessage `json:"lines"`
	}
	entries := []entry{}
	for _, trigger := range slices.Sorted(maps.Keys(book)) {
		for _, mood := range slices.Sorted(maps.Keys(book[trigger])) {
			entries = append(entries, entry{Trigger: trigger, Mood: mood, Lines: book[trigger][mood]})
		}
	}
	return json.Marshal(entries)
}

// cityLevel rounds a coordinate to one decimal (~11 km), which is all the chart and flavor text need.
func cityLevel(v *float64) *float64 {
	if v == nil {
		return nil
	}
	rounded := math.Round(*v*10) / 10
	return &rounded
}
