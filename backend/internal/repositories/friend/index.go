package friend

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type FriendRepo interface {
	Create(ctx context.Context, m *model.Friend) (*model.Friend, error)
	GetByID(ctx context.Context, id string) (*model.Friend, error)
	GetByUserID(ctx context.Context, userID string) (*model.Friend, error)
	SetCurrentVersion(ctx context.Context, friendID, versionID string) error
	// ListDueForEvolution returns friends with a ready personality whose weekly evolution is due, oldest due first.
	ListDueForEvolution(ctx context.Context, now time.Time, limit int) ([]model.Friend, error)
	SetNextEvolutionAt(ctx context.Context, friendID string, next time.Time) error
}

type friendRepo struct {
	dbdget db.DBGormDelegate
}

func NewFriendRepo(dbdget db.DBGormDelegate) FriendRepo {
	return &friendRepo{
		dbdget: dbdget,
	}
}
