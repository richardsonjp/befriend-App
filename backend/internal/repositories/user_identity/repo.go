package user_identity

import (
	"context"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/pkg/clients/db"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
)

func (r *userIdentityRepo) Create(ctx context.Context, m *model.UserIdentity) (*model.UserIdentity, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		if db.IsUniqueViolation(err) {
			return nil, errors.From("DATA_CONFLICT")
		}
		return nil, err
	}
	return m, nil
}

func (r *userIdentityRepo) GetByProviderSubject(ctx context.Context, provider enum.IdentityProvider, subject string) (*model.UserIdentity, error) {
	m := &model.UserIdentity{}
	q := r.dbdget.Get(ctx).Where("provider = ? AND subject = ?", provider, subject).Take(m)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return m, nil
}

func (r *userIdentityRepo) UpdateAppleRefreshToken(ctx context.Context, id, token, clientID string) error {
	return r.dbdget.Get(ctx).
		Model(&model.UserIdentity{}).
		Where("id = ?", id).
		Updates(map[string]interface{}{"apple_refresh_token": token, "apple_client_id": clientID, "updated_at": gorm.Expr("NOW()")}).Error
}

// ListAppleTokens returns the user's Apple identities that hold a refresh token.
func (r *userIdentityRepo) ListAppleTokens(ctx context.Context, userID string) ([]model.UserIdentity, error) {
	var identities []model.UserIdentity
	err := r.dbdget.Get(ctx).
		Where("user_id = ? AND provider = ? AND apple_refresh_token IS NOT NULL", userID, enum.APPLE).
		Find(&identities).Error
	return identities, err
}
