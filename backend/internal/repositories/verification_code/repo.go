package verification_code

import (
	"context"
	"befriend/internal/model"
	"befriend/pkg/utils/errors"
)

func (r *verificationCodeRepo) Create(ctx context.Context, m *model.VerificationCode) (*model.VerificationCode, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return nil, err
	}
	return m, nil
}

func (r *verificationCodeRepo) Get(ctx context.Context, tableType, userID, code string) (*model.VerificationCode, error) {
	var m model.VerificationCode
	if err := r.dbdget.Get(ctx).Where("table_type = ? AND user_id = ? AND code = ?", tableType, userID, code).First(&m).Error; err != nil {
		return nil, err
	}
	return &m, nil
}

func (r *verificationCodeRepo) Delete(ctx context.Context, tableType, userID, code string) error {
	result := r.dbdget.Get(ctx).
		Where("table_type = ? AND user_id = ? AND code = ?", tableType, userID, code). // Note: Fixed 'table_type' to 'type' based on your schema
		Delete(&model.VerificationCode{})

	if result.Error != nil {
		return result.Error // Actual DB error (connection died, syntax error)
	}

	if result.RowsAffected == 0 {
		return errors.From("DATA_NOT_FOUND")
		// Or return nil if you consider "idempotent delete" a success
	}

	return nil
}
