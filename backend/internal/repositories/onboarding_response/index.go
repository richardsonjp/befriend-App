package onboarding_response

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type OnboardingResponseRepo interface {
	Create(ctx context.Context, m *model.OnboardingResponse) error
	GetByUserID(ctx context.Context, userID string) (*model.OnboardingResponse, error)
}

type onboardingResponseRepo struct {
	dbdget db.DBGormDelegate
}

func NewOnboardingResponseRepo(dbdget db.DBGormDelegate) OnboardingResponseRepo {
	return &onboardingResponseRepo{
		dbdget: dbdget,
	}
}
