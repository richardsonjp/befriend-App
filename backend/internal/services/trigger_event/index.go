package trigger_event

import (
	"context"

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
