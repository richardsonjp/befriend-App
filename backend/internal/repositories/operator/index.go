package operator

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/pkg/clients/db"
)

type OperatorRepo interface {
	Create(ctx context.Context, m *model.Operator) error
	Update(ctx context.Context, m model.Operator, updatedFields ...string) (int64, error)
	GetByEmail(ctx context.Context, email string) (*model.Operator, error)
}

type operatorRepo struct {
	dbdget db.DBGormDelegate
}

func NewOperatorRepo(dbdget db.DBGormDelegate) OperatorRepo {
	return &operatorRepo{
		dbdget: dbdget,
	}
}
