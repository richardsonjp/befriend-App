package refresh_token

import (
	"context"

	"befriend/internal/model"
	"befriend/internal/repositories/refresh_token"
	"befriend/internal/repositories/tx"
)

type RefreshTokenService interface {
	Create(ctx context.Context, payload CreatePayload) error
	GetForRotation(ctx context.Context, tokenHash string) (*model.RefreshToken, error)
	MarkRotated(ctx context.Context, id string) error
	RevokeByDevice(ctx context.Context, deviceID string) error
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
