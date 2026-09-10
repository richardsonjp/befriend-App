package friend

import (
	"context"
	"time"

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

func (r *friendRepo) GetByID(ctx context.Context, id string) (*model.Friend, error) {
	return r.take(ctx, "id = ?", id)
}

func (r *friendRepo) GetByUserID(ctx context.Context, userID string) (*model.Friend, error) {
	return r.take(ctx, "user_id = ?", userID)
}

func (r *friendRepo) SetCurrentVersion(ctx context.Context, friendID, versionID string) error {
	return r.dbdget.Get(ctx).
		Model(&model.Friend{}).
		Where("id = ?", friendID).
		Updates(map[string]interface{}{"current_version_id": versionID, "updated_at": gorm.Expr("NOW()")}).Error
}

func (r *friendRepo) ListDueForEvolution(ctx context.Context, now time.Time, limit int) ([]model.Friend, error) {
	var friends []model.Friend
	err := r.dbdget.Get(ctx).
		Where("next_evolution_at <= ? AND current_version_id IS NOT NULL", now).
		Order("next_evolution_at").
		Limit(limit).
		Find(&friends).Error
	return friends, err
}

func (r *friendRepo) SetNextEvolutionAt(ctx context.Context, friendID string, next time.Time) error {
	return r.dbdget.Get(ctx).
		Model(&model.Friend{}).
		Where("id = ?", friendID).
		Updates(map[string]interface{}{"next_evolution_at": next, "updated_at": gorm.Expr("NOW()")}).Error
}

func (r *friendRepo) take(ctx context.Context, where string, arg string) (*model.Friend, error) {
	m := &model.Friend{}
	q := r.dbdget.Get(ctx).Where(where, arg).Take(m)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return m, nil
}
