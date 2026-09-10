package friend

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type FriendRepo interface {
	Create(ctx context.Context, m *model.Friend) (*model.Friend, error)
	GetByUserID(ctx context.Context, userID string) (*model.Friend, error)
}

type friendRepo struct {
	dbdget db.DBGormDelegate
}

func NewFriendRepo(dbdget db.DBGormDelegate) FriendRepo {
	return &friendRepo{
		dbdget: dbdget,
	}
}
