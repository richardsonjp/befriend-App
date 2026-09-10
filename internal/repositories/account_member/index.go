package account_member

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/pkg/clients/db"
)

type AccountMemberRepo interface {
	Create(ctx context.Context, m *model.AccountMember) error
	Update(ctx context.Context, m model.AccountMember, updatedFields ...string) (int64, error)
	GetByUserID(ctx context.Context, userID string) (*model.AccountMember, error)
}

type accountMemberRepo struct {
	dbdget db.DBGormDelegate
}

func NewAccountMemberRepo(dbdget db.DBGormDelegate) AccountMemberRepo {
	return &accountMemberRepo{
		dbdget: dbdget,
	}
}
