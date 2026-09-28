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
	// ProcessDue generates up to limit due evolutions and returns how many it took (the evolve job).
	ProcessDue(ctx context.Context, limit int) (int, error)
	// Hatch writes the user's friend's first personality while the caller waits. Nothing retries a failed hatch:
	// the error goes back to the app, which offers Try again. Already hatched is a success.
	Hatch(ctx context.Context, userID string) error
	// Reskin rewrites a hatched friend's phrasebook for the picked skin (nil = built-in) while the caller waits,
	// then switches the user to it. On failure the user keeps the skin they had.
	Reskin(ctx context.Context, friendID string, skinID *string) error
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
	openRouter                *openrouter.Client // nil when no API key is configured: nothing can be written
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
