package onboarding_response

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
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

func (r *onboardingResponseRepo) GetByUserID(ctx context.Context, userID string) (*model.OnboardingResponse, error) {
	m := &model.OnboardingResponse{}
	q := r.dbdget.Get(ctx).Where("user_id = ?", userID).Take(m)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return m, nil
}
