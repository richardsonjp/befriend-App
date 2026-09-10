package refresh_token

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type RefreshTokenRepo interface {
	Create(ctx context.Context, m *model.RefreshToken) error
	GetByHashForUpdate(ctx context.Context, tokenHash string) (*model.RefreshToken, error)
	MarkRotated(ctx context.Context, id string, rotatedAt time.Time) error
	RevokeByDevice(ctx context.Context, deviceID string, revokedAt time.Time) error
}

type refreshTokenRepo struct {
	dbdget db.DBGormDelegate
}

func NewRefreshTokenRepo(dbdget db.DBGormDelegate) RefreshTokenRepo {
	return &refreshTokenRepo{
		dbdget: dbdget,
	}
}
