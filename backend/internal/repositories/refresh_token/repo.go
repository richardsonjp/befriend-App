package refresh_token

import (
	"context"
	"time"

	"befriend/internal/model"
)

func (r *refreshTokenRepo) Create(ctx context.Context, m *model.RefreshToken) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

func (r *refreshTokenRepo) RevokeByDevice(ctx context.Context, deviceID string, revokedAt time.Time) error {
	return r.dbdget.Get(ctx).
		Model(&model.RefreshToken{}).
		Where("device_id = ? AND revoked_at IS NULL", deviceID).
		Update("revoked_at", revokedAt).Error
}
