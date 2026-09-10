package user_identity

import (
	"context"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/internal/repositories/tx"
	repoUserIdentity "befriend/internal/repositories/user_identity"
)

type UserIdentityService interface {
	Create(ctx context.Context, payload CreatePayload) (*model.UserIdentity, error)
	GetByProviderSubject(ctx context.Context, provider enum.IdentityProvider, subject string) (*model.UserIdentity, error)
	UpdateAppleRefreshToken(ctx context.Context, id, token string) error
}

type userIdentityService struct {
	txRepo           tx.TxRepo
	userIdentityRepo repoUserIdentity.UserIdentityRepo
}

func NewUserIdentityService(txRepo tx.TxRepo,
	userIdentityRepo repoUserIdentity.UserIdentityRepo) UserIdentityService {
	return &userIdentityService{
		txRepo:           txRepo,
		userIdentityRepo: userIdentityRepo,
	}
}
