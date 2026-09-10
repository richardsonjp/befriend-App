package user_identity

import (
	"context"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/pkg/clients/db"
)

type UserIdentityRepo interface {
	Create(ctx context.Context, m *model.UserIdentity) (*model.UserIdentity, error)
	GetByProviderSubject(ctx context.Context, provider enum.IdentityProvider, subject string) (*model.UserIdentity, error)
	UpdateAppleRefreshToken(ctx context.Context, id, token string) error
}

type userIdentityRepo struct {
	dbdget db.DBGormDelegate
}

func NewUserIdentityRepo(dbdget db.DBGormDelegate) UserIdentityRepo {
	return &userIdentityRepo{
		dbdget: dbdget,
	}
}
