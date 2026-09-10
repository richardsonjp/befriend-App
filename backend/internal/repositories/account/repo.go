package account

import (
	"context"
	"befriend/internal/model"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
)

func (r *accountRepo) Create(ctx context.Context, m *model.Account) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

func (r *accountRepo) Update(ctx context.Context, m model.Account, updatedFields ...string) (int64, error) {
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

func (r *accountRepo) GetByID(ctx context.Context, ID string) (*model.Account, error) {
	var m model.Account

	db := r.dbdget.Get(ctx)

	err := db.Where("id = ?", ID).
		First(&m).Error

	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, err
	}

	return &m, nil
}
