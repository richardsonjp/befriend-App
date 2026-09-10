package friend

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
)

func (r *friendRepo) Create(ctx context.Context, m *model.Friend) (*model.Friend, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		if db.IsUniqueViolation(err) {
			return nil, errors.From("DATA_CONFLICT")
		}
		return nil, err
	}
	return m, nil
}

func (r *friendRepo) GetByUserID(ctx context.Context, userID string) (*model.Friend, error) {
	m := &model.Friend{}
	q := r.dbdget.Get(ctx).Where("user_id = ?", userID).Take(m)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return m, nil
}
