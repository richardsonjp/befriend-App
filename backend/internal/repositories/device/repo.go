package device

import (
	"context"

	"befriend/internal/model"
	"befriend/internal/model/enum"
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

func (r *deviceRepo) ListPushTargets(ctx context.Context, userID string) ([]model.Device, error) {
	var devices []model.Device
	err := r.dbdget.Get(ctx).
		Where("user_id = ? AND platform = ? AND apns_env IS NOT NULL", userID, enum.IOS).
		Where("la_push_token IS NOT NULL OR la_push_to_start_token IS NOT NULL OR widget_push_token IS NOT NULL").
		Find(&devices).Error
	return devices, err
}

// ClearColumns sets columns to NULL; callers pass fixed column names only.
func (r *deviceRepo) ClearColumns(ctx context.Context, id string, columns ...string) error {
	fields := make(map[string]interface{}, len(columns))
	for _, column := range columns {
		fields[column] = nil
	}
	return r.dbdget.Get(ctx).Model(&model.Device{}).Where("id = ?", id).Updates(fields).Error
}
