package refresh_token

import (
	"context"
	"go-skeleton/internal/repositories/refresh_token"
	"go-skeleton/internal/repositories/tx"
)

type RefreshTokenService interface {
	Create(ctx context.Context, payload CreatePayload) error
}

type refreshTokenService struct {
	txRepo           tx.TxRepo
	refreshTokenRepo refresh_token.RefreshTokenRepo
}

func NewRefreshTokenService(txRepo tx.TxRepo,
	refreshTokenRepo refresh_token.RefreshTokenRepo) RefreshTokenService {
	return &refreshTokenService{
		txRepo:           txRepo,
		refreshTokenRepo: refreshTokenRepo,
	}
}
