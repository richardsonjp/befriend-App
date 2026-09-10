package device

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"
)

func (r *deviceRepo) Create(ctx context.Context, m *model.Device) (*model.Device, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return nil, err
	}
	return m, nil
}

// UpdatePushTokens writes the given columns on the user's device; nil values clear columns.
func (r *deviceRepo) UpdatePushTokens(ctx context.Context, id, userID string, fields map[string]interface{}) error {
	q := r.dbdget.Get(ctx).
		Model(&model.Device{}).
		Where("id = ? AND user_id = ?", id, userID).
		Updates(fields)
	if q.Error != nil {
		return q.Error
	}
	if q.RowsAffected == 0 {
		return errors.From("DATA_NOT_FOUND")
	}
	return nil
}
