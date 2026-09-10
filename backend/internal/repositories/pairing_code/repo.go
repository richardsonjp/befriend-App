package pairing_code

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

func (r *pairingCodeRepo) Create(ctx context.Context, m *model.PairingCode) error {
	return r.dbdget.Get(ctx).Create(m).Error
}

func (r *pairingCodeRepo) GetByCodeHash(ctx context.Context, codeHash string, forUpdate bool) (*model.PairingCode, error) {
	q := r.dbdget.Get(ctx)
	if forUpdate {
		q = q.Clauses(clause.Locking{Strength: "UPDATE"})
	}
	m := &model.PairingCode{}
	if err := q.Where("code_hash = ?", codeHash).Take(m).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, err
	}
	return m, nil
}

func (r *pairingCodeRepo) Confirm(ctx context.Context, id, userID string, at time.Time) error {
	return r.dbdget.Get(ctx).
		Model(&model.PairingCode{}).
		Where("id = ?", id).
		Updates(map[string]interface{}{"user_id": userID, "confirmed_at": at}).Error
}

func (r *pairingCodeRepo) DeleteExpiredBefore(ctx context.Context, before time.Time) (int64, error) {
	q := r.dbdget.Get(ctx).Where("expires_at < ?", before).Delete(&model.PairingCode{})
	return q.RowsAffected, q.Error
}

func (r *pairingCodeRepo) MarkConsumed(ctx context.Context, id string, at time.Time) error {
	return r.dbdget.Get(ctx).
		Model(&model.PairingCode{}).
		Where("id = ?", id).
		Update("consumed_at", at).Error
}
