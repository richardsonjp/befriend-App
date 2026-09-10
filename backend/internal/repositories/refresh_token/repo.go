package refresh_token

import (
	"context"
	"befriend/internal/model"
)

func (r *refreshTokenRepo) Create(ctx context.Context, m *model.RefreshToken) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

func (r *refreshTokenRepo) Update(ctx context.Context, m model.RefreshToken, updatedFields ...string) (int64, error) {
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
