package user_application

type MeResponse struct {
	ID             string  `json:"id"`
	Email          *string `json:"email"`
	OnboardingDone bool    `json:"onboarding_done"`
}
