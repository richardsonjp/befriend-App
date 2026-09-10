package verification_code

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
)

func (r *verificationCodeRepo) Create(ctx context.Context, m *model.VerificationCode) (*model.VerificationCode, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return nil, err
	}
	return m, nil
}

func (r *verificationCodeRepo) GetLatest(ctx context.Context, tableType, userID string) (*model.VerificationCode, error) {
	m := &model.VerificationCode{}
	q := r.dbdget.Get(ctx).
		Where("table_type = ? AND user_id = ?", tableType, userID).
		Order("created_at DESC").
		Take(m)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return m, nil
}

func (r *verificationCodeRepo) IncrementAttempts(ctx context.Context, id string) error {
	return r.dbdget.Get(ctx).
		Model(&model.VerificationCode{}).
		Where("id = ?", id).
		UpdateColumn("attempts", gorm.Expr("attempts + 1")).Error
}

func (r *verificationCodeRepo) DeleteAll(ctx context.Context, tableType, userID string) error {
	return r.dbdget.Get(ctx).
		Where("table_type = ? AND user_id = ?", tableType, userID).
		Delete(&model.VerificationCode{}).Error
}
