package operator

import (
	"context"
	"befriend/internal/model"
)

func (r *operatorRepo) Create(ctx context.Context, m *model.Operator) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

func (r *operatorRepo) Update(ctx context.Context, m model.Operator, updatedFields ...string) (int64, error) {
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

func (r *operatorRepo) GetByEmail(ctx context.Context, email string) (*model.Operator, error) {
	var result model.Operator
	if err := r.dbdget.Get(ctx).Where("email = ?", email).First(&result).Error; err != nil {
		return nil, err
	}
	return &result, nil
}
