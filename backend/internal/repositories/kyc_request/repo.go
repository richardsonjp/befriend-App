package kyc_request

import (
	"context"
	"go-skeleton/internal/model"
)

func (r *kycRequestRepo) Create(ctx context.Context, m *model.KycRequest) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

func (r *kycRequestRepo) Update(ctx context.Context, m model.KycRequest, updatedFields ...string) (int64, error) {
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
