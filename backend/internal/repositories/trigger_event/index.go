package trigger_event

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type TriggerEventRepo interface {
	// InsertNew stores events, skipping ones already uploaded (same client_event_id), and returns how many were new.
	InsertNew(ctx context.Context, events []model.TriggerEvent) (int64, error)
	DeleteByUser(ctx context.Context, userID string) error
	// DeleteByApps removes the user's events for these app names (compared lowercased).
	DeleteByApps(ctx context.Context, userID string, lowerAppNames []string) error
}

type triggerEventRepo struct {
	dbdget db.DBGormDelegate
}

func NewTriggerEventRepo(dbdget db.DBGormDelegate) TriggerEventRepo {
	return &triggerEventRepo{
		dbdget: dbdget,
	}
}
