package refresh_token

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

func (r *refreshTokenRepo) Create(ctx context.Context, m *model.RefreshToken) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

// GetByHashForUpdate locks the row (SELECT ... FOR UPDATE) so concurrent refreshes of the same token
// serialize. Must run inside a transaction.
func (r *refreshTokenRepo) GetByHashForUpdate(ctx context.Context, tokenHash string) (*model.RefreshToken, error) {
	m := &model.RefreshToken{}
	q := r.dbdget.Get(ctx).
		Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("token_hash = ?", tokenHash).
		Take(m)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return m, nil
}

// MarkRotated records the first rotation only, so the reuse grace window counts from it.
func (r *refreshTokenRepo) MarkRotated(ctx context.Context, id string, rotatedAt time.Time) error {
	return r.dbdget.Get(ctx).
		Model(&model.RefreshToken{}).
		Where("id = ? AND rotated_at IS NULL", id).
		Update("rotated_at", rotatedAt).Error
}

func (r *refreshTokenRepo) RevokeByDevice(ctx context.Context, deviceID string, revokedAt time.Time) error {
	return r.dbdget.Get(ctx).
		Model(&model.RefreshToken{}).
		Where("device_id = ? AND revoked_at IS NULL", deviceID).
		Update("revoked_at", revokedAt).Error
}
