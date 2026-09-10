package presence

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type PresenceRepo interface {
	// GetForUpdate creates the user's row if needed and locks it (call inside a transaction).
	GetForUpdate(ctx context.Context, userID string) (*model.Presence, error)
	Get(ctx context.Context, userID string) (*model.Presence, error)
	Save(ctx context.Context, m *model.Presence) error
	// ListDue returns users whose owner may be out of date (a Mac went quiet, a phone claim lapsed) or whose
	// last owner change hasn't been pushed yet.
	ListDue(ctx context.Context, now, macSeenAfter, pushedBefore time.Time, limit int) ([]string, error)
}

type presenceRepo struct {
	dbdget db.DBGormDelegate
}

func NewPresenceRepo(dbdget db.DBGormDelegate) PresenceRepo {
	return &presenceRepo{
		dbdget: dbdget,
	}
}
