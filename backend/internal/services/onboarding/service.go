package onboarding

import (
	"context"
	"time"

	"befriend/internal/model"
	ct "befriend/internal/model/custom_type"
	"befriend/internal/services/friend"
	"befriend/internal/services/skin"
	"befriend/pkg/utils/astro"
	"befriend/pkg/utils/errors"
)

const (
	friendNameQuestion   = "friend_name"
	userNicknameQuestion = "user_nickname"
	evolutionInterval    = 7 * 24 * time.Hour
	// dogSkin is the published skin a "dog" pick is granted, free.
	dogSkin = "pixel-dog"
)

func (s *onboardingService) GetQuestions(ctx context.Context) (*QuestionsResponse, error) {
	set, err := s.questionSetService.GetActive(ctx)
	if err != nil {
		return nil, err
	}
	return &QuestionsResponse{Version: set.Version, Questions: set.Questions.Data}, nil
}

// Complete stores the answers, applies the cat-or-dog pick, and creates the friend: born now, with its chart, and
// version 1 of its personality queued for POST /friend/hatch. Onboarding can only be completed once.
func (s *onboardingService) Complete(ctx context.Context, userID string, payload CompletePayload) (*friend.ProfileResponse, error) {
	if !payload.Consent {
		return nil, errors.From("VALIDATION_FAILED").WithDetail("consent is required")
	}

	set, err := s.questionSetService.GetActive(ctx)
	if err != nil {
		return nil, err
	}
	if set.Version != payload.QuestionSetVersion {
		return nil, errors.From("DATA_CONFLICT").WithDetail("the questions have changed; reload them and answer again")
	}

	answers, err := normalizeAnswers(set.Questions.Data, payload.Answers)
	if err != nil {
		return nil, errors.From("VALIDATION_FAILED").WithDetail(err.Error())
	}
	name, nickname := textAnswer(answers, friendNameQuestion), textAnswer(answers, userNicknameQuestion)
	if name == "" || nickname == "" {
		return nil, errors.From("INTERNAL_SERVER_ERROR").WithDetail("active question set lacks the name questions")
	}

	if _, err := time.LoadLocation(payload.Timezone); err != nil || payload.Timezone == "Local" {
		return nil, errors.From("VALIDATION_FAILED").WithDetail("timezone must be an IANA name such as Asia/Jakarta")
	}

	bornAt := time.Now().UTC()
	create := friend.CreatePayload{
		UserID:          userID,
		Name:            name,
		UserNickname:    nickname,
		BornAt:          bornAt,
		Timezone:        payload.Timezone,
		Chart:           astro.ChartAt(bornAt),
		NextEvolutionAt: bornAt.Add(evolutionInterval),
	}
	if payload.Location != nil {
		create.City = payload.Location.City
		create.CountryCode = payload.Location.CountryCode
		create.Latitude = payload.Location.Latitude
		create.Longitude = payload.Location.Longitude
	}

	err = s.txRepo.Run(ctx, func(ctx context.Context) error {
		err := s.onboardingResponseRepo.Create(ctx, &model.OnboardingResponse{
			UserID:        userID,
			QuestionSetID: set.ID,
			Answers:       ct.JSONB[[]model.Answer]{Data: answers},
			ConsentAt:     bornAt,
		})
		if err != nil {
			if errors.Is(err, "DATA_CONFLICT") {
				return errors.From("DATA_CONFLICT").WithDetail("onboarding is already complete")
			}
			return err
		}

		if err := s.pickSpecies(ctx, userID, payload.Species); err != nil {
			return err
		}
		newFriend, err := s.friendService.Create(ctx, create)
		if err != nil {
			return err
		}
		_, err = s.personalityVersionService.CreateInitial(ctx, newFriend.ID)
		return err
	})
	if err != nil {
		return nil, err
	}

	return s.friendService.GetProfile(ctx, userID)
}

// pickSpecies sets the skin the friend hatches in. The dog is granted first: only a granted skin can be picked.
func (s *onboardingService) pickSpecies(ctx context.Context, userID, species string) error {
	switch species {
	case "cat":
		return s.userService.UpdateSkin(ctx, userID, nil)
	case "dog":
		if err := s.skinService.Grant(ctx, skin.GrantPayload{SkinID: dogSkin, UserID: userID}); err != nil {
			return err
		}
		id := dogSkin
		return s.userService.UpdateSkin(ctx, userID, &id)
	}
	return nil
}

func textAnswer(answers []model.Answer, questionID string) string {
	for _, a := range answers {
		if a.QuestionID == questionID {
			s, _ := a.Value.(string)
			return s
		}
	}
	return ""
}
