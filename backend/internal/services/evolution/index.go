package evolution

import (
	"context"

	"befriend/internal/repositories/tx"
	"befriend/internal/services/friend"
	"befriend/internal/services/pairing_code"
	"befriend/internal/services/personality"
	"befriend/internal/services/personality_version"
	"befriend/internal/services/trigger_event"
)

// EvolutionService is the hourly maintenance job (`apiserver evolve`): retention cleanup, then each due friend's
// weekly evolution.
type EvolutionService interface {
	Run(ctx context.Context) (*RunSummary, error)
}

type RunSummary struct {
	EventsDeleted       int64
	PairingCodesDeleted int64
	Queued              int
	Generated           int
}

type evolutionService struct {
	txRepo                    tx.TxRepo
	friendService             friend.FriendService
	personalityVersionService personality_version.PersonalityVersionService
	personalityService        personality.PersonalityService
	triggerEventService       trigger_event.TriggerEventService
	pairingCodeService        pairing_code.PairingCodeService
}

func NewEvolutionService(
	txRepo tx.TxRepo,
	friendService friend.FriendService,
	personalityVersionService personality_version.PersonalityVersionService,
	personalityService personality.PersonalityService,
	triggerEventService trigger_event.TriggerEventService,
	pairingCodeService pairing_code.PairingCodeService,
) EvolutionService {
	return &evolutionService{
		txRepo:                    txRepo,
		friendService:             friendService,
		personalityVersionService: personalityVersionService,
		personalityService:        personalityService,
		triggerEventService:       triggerEventService,
		pairingCodeService:        pairingCodeService,
	}
}
