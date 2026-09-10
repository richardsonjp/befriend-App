package user

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
)

func (r *userRepo) Create(ctx context.Context, m *model.User) (*model.User, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		if db.IsUniqueViolation(err) {
			return nil, errors.From("DATA_CONFLICT")
		}
		return nil, err
	}
	return m, nil
}

func (r *userRepo) Update(ctx context.Context, m model.User, updatedFields ...string) (int64, error) {
	query := r.dbdget.Get(ctx).
		Model(&m).
		Where("id = ?", m.ID)

	if len(updatedFields) > 0 {
		updatedFields = append(updatedFields, "updated_at")
		query = query.Select(updatedFields)
	}

	query.Updates(m)

	if query.Error != nil {
		return 0, query.Error
	}

	return query.RowsAffected, nil
}

func (r *userRepo) GetByID(ctx context.Context, id string) (*model.User, error) {
	user := &model.User{}
	q := r.dbdget.Get(ctx).Where("id = ?", id).First(user)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return user, nil
}

// Delete removes the account; foreign keys cascade to its identities, devices, tokens, onboarding and friend.
func (r *userRepo) Delete(ctx context.Context, id string) error {
	q := r.dbdget.Get(ctx).Where("id = ?", id).Delete(&model.User{})
	if q.Error != nil {
		return q.Error
	}
	if q.RowsAffected == 0 {
		return errors.From("DATA_NOT_FOUND")
	}
	return nil
}

func (r *userRepo) GetByEmail(ctx context.Context, email string) (*model.User, error) {
	user := &model.User{}
	q := r.dbdget.Get(ctx).Where("lower(email) = lower(?)", email).First(user)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return user, nil
}
