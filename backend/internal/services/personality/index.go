package personality

import (
	"context"

	repoLLMBudget "befriend/internal/repositories/llm_budget"
	"befriend/internal/repositories/tx"
	"befriend/internal/services/friend"
	"befriend/internal/services/onboarding"
	"befriend/internal/services/personality_version"
	"befriend/pkg/clients/openrouter"
)

type PersonalityService interface {
	// ProcessDue generates up to limit queued personality versions and returns how many it took.
	ProcessDue(ctx context.Context, limit int) (int, error)
}

type personalityService struct {
	txRepo                    tx.TxRepo
	llmBudgetRepo             repoLLMBudget.LLMBudgetRepo
	personalityVersionService personality_version.PersonalityVersionService
	friendService             friend.FriendService
	onboardingService         onboarding.OnboardingService
	openRouter                *openrouter.Client // nil when no API key is configured: the queue waits
}

func NewPersonalityService(
	txRepo tx.TxRepo,
	llmBudgetRepo repoLLMBudget.LLMBudgetRepo,
	personalityVersionService personality_version.PersonalityVersionService,
	friendService friend.FriendService,
	onboardingService onboarding.OnboardingService,
	openRouter *openrouter.Client,
) PersonalityService {
	return &personalityService{
		txRepo:                    txRepo,
		llmBudgetRepo:             llmBudgetRepo,
		personalityVersionService: personalityVersionService,
		friendService:             friendService,
		onboardingService:         onboardingService,
		openRouter:                openRouter,
	}
}
