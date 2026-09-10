package onboarding

import (
	"befriend/internal/services/onboarding"
)

type OnboardingHandler struct {
	onboardingService onboarding.OnboardingService
}

func NewOnboardingHandler(onboardingService onboarding.OnboardingService) *OnboardingHandler {
	return &OnboardingHandler{
		onboardingService: onboardingService,
	}
}
