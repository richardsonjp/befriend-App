package onboarding_response

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
	"befriend/pkg/utils/errors"
)

func (r *onboardingResponseRepo) Create(ctx context.Context, m *model.OnboardingResponse) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		if db.IsUniqueViolation(err) {
			return errors.From("DATA_CONFLICT")
		}
		return err
	}
	return nil
}
