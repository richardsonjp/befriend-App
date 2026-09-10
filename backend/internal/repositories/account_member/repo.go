package account_member

import (
	"context"
	"befriend/internal/model"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
)

func (r *accountMemberRepo) Create(ctx context.Context, m *model.AccountMember) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

func (r *accountMemberRepo) Update(ctx context.Context, m model.AccountMember, updatedFields ...string) (int64, error) {
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

func (r *accountMemberRepo) GetByUserID(ctx context.Context, userID string) (*model.AccountMember, error) {
	var m model.AccountMember
	if err := r.dbdget.Get(ctx).Where("user_id = ?", userID).First(&m).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, err
	}
	return &m, nil
}
