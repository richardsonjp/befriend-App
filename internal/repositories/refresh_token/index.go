package refresh_token

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/pkg/clients/db"
)

type RefreshTokenRepo interface {
	Create(ctx context.Context, m *model.RefreshToken) error
	Update(ctx context.Context, m model.RefreshToken, updatedFields ...string) (int64, error)
}

type refreshTokenRepo struct {
	dbdget db.DBGormDelegate
}

func NewRefreshTokenRepo(dbdget db.DBGormDelegate) RefreshTokenRepo {
	return &refreshTokenRepo{
		dbdget: dbdget,
	}
}
