package trigger_event

import (
	"context"
	"time"

	"befriend/internal/model"
	repoTriggerEvent "befriend/internal/repositories/trigger_event"
	"befriend/internal/repositories/tx"
	"befriend/internal/services/user"
)

type TriggerEventService interface {
	// Record stores an upload from a device, honouring the user's pause and excluded apps.
	Record(ctx context.Context, payload RecordPayload) (*RecordResponse, error)
	DeleteAll(ctx context.Context, userID string) error
	// DeleteByApps removes events for app names the user just excluded.
	DeleteByApps(ctx context.Context, userID string, appNames []string) error
	// Recent returns up to limit of the user's latest events, oldest first.
	Recent(ctx context.Context, userID string, limit int) ([]model.TriggerEvent, error)
	// DeleteExpired removes events older than Retention and returns how many.
	DeleteExpired(ctx context.Context, now time.Time) (int64, error)
}

type triggerEventService struct {
	txRepo           tx.TxRepo
	triggerEventRepo repoTriggerEvent.TriggerEventRepo
	userService      user.UserService
}

func NewTriggerEventService(txRepo tx.TxRepo,
	triggerEventRepo repoTriggerEvent.TriggerEventRepo,
	userService user.UserService) TriggerEventService {
	return &triggerEventService{
		txRepo:           txRepo,
		triggerEventRepo: triggerEventRepo,
		userService:      userService,
	}
}
