package account

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/pkg/clients/db"
)

type AccountRepo interface {
	Create(ctx context.Context, m *model.Account) error
	Update(ctx context.Context, m model.Account, updatedFields ...string) (int64, error)
	GetByID(ctx context.Context, ID string) (*model.Account, error)
}

type accountRepo struct {
	dbdget db.DBGormDelegate
}

func NewAccountRepo(dbdget db.DBGormDelegate) AccountRepo {
	return &accountRepo{
		dbdget: dbdget,
	}
}
