package personality

import (
	"context"

	repoLLMBudget "befriend/internal/repositories/llm_budget"
	"befriend/internal/repositories/tx"
	"befriend/internal/services/friend"
	"befriend/internal/services/onboarding"
	"befriend/internal/services/personality_version"
	"befriend/internal/services/skin"
	"befriend/internal/services/trigger_event"
	"befriend/internal/services/user"
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
	triggerEventService       trigger_event.TriggerEventService
	userService               user.UserService
	skinService               skin.SkinService
	openRouter                *openrouter.Client // nil when no API key is configured: the queue waits
}

func NewPersonalityService(
	txRepo tx.TxRepo,
	llmBudgetRepo repoLLMBudget.LLMBudgetRepo,
	personalityVersionService personality_version.PersonalityVersionService,
	friendService friend.FriendService,
	onboardingService onboarding.OnboardingService,
	triggerEventService trigger_event.TriggerEventService,
	userService user.UserService,
	skinService skin.SkinService,
	openRouter *openrouter.Client,
) PersonalityService {
	return &personalityService{
		txRepo:                    txRepo,
		llmBudgetRepo:             llmBudgetRepo,
		personalityVersionService: personalityVersionService,
		friendService:             friendService,
		onboardingService:         onboardingService,
		triggerEventService:       triggerEventService,
		userService:               userService,
		skinService:               skinService,
		openRouter:                openRouter,
	}
}
