package friend

import (
	"context"
	"math"
	"strings"

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

// GetProfile is the friend as the apps see it: the latest personality version's status, plus the
// content and phrasebook of the current ready version once one exists.
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
			profile.Phrasebook = current.Phrasebook.Data
		}
		if current.VocabularyVersion != nil {
			profile.Personality.VocabularyVersion = *current.VocabularyVersion
		}
	}
	return profile, nil
}

// cityLevel rounds a coordinate to one decimal (~11 km), which is all the chart and flavor text need.
func cityLevel(v *float64) *float64 {
	if v == nil {
		return nil
	}
	rounded := math.Round(*v*10) / 10
	return &rounded
}
