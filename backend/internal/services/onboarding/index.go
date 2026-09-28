package onboarding

import (
	"context"

	repoOnboardingResponse "befriend/internal/repositories/onboarding_response"
	"befriend/internal/repositories/tx"
	"befriend/internal/services/friend"
	"befriend/internal/services/personality_version"
	"befriend/internal/services/question_set"
	"befriend/internal/services/skin"
	"befriend/internal/services/user"
)

type OnboardingService interface {
	GetQuestions(ctx context.Context) (*QuestionsResponse, error)
	Complete(ctx context.Context, userID string, payload CompletePayload) (*friend.ProfileResponse, error)
	GetAnsweredQuestions(ctx context.Context, userID string) ([]AnsweredQuestion, error)
}

type onboardingService struct {
	txRepo                    tx.TxRepo
	onboardingResponseRepo    repoOnboardingResponse.OnboardingResponseRepo
	questionSetService        question_set.QuestionSetService
	friendService             friend.FriendService
	personalityVersionService personality_version.PersonalityVersionService
	skinService               skin.SkinService
	userService               user.UserService
}

func NewOnboardingService(
	txRepo tx.TxRepo,
	onboardingResponseRepo repoOnboardingResponse.OnboardingResponseRepo,
	questionSetService question_set.QuestionSetService,
	friendService friend.FriendService,
	personalityVersionService personality_version.PersonalityVersionService,
	skinService skin.SkinService,
	userService user.UserService,
) OnboardingService {
	return &onboardingService{
		txRepo:                    txRepo,
		onboardingResponseRepo:    onboardingResponseRepo,
		questionSetService:        questionSetService,
		friendService:             friendService,
		personalityVersionService: personalityVersionService,
		skinService:               skinService,
		userService:               userService,
	}
}
