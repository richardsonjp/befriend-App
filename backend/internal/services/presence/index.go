package presence

import (
	"context"
	"time"

	repoPresence "befriend/internal/repositories/presence"
	"befriend/internal/repositories/tx"
	"befriend/internal/services/device"
	"befriend/internal/services/friend"
	"befriend/pkg/clients/apns"
)

type PresenceService interface {
	Get(ctx context.Context, userID string) (*StateResponse, error)
	// MacHeartbeat records the Mac's state (sent on change and every 30 seconds).
	MacHeartbeat(ctx context.Context, userID string, active bool) error
	// MacDisconnected marks the Mac inactive when its last connection closes, unless a heartbeat newer than that
	// connection's last one already arrived (a reconnect racing the old teardown).
	MacDisconnected(ctx context.Context, userID string, lastHeartbeat time.Time) error
	// ClaimPhone: the iPhone app is in the foreground (renewed every minute).
	ClaimPhone(ctx context.Context, userID string) (*StateResponse, error)
	ReleasePhone(ctx context.Context, userID string) (*StateResponse, error)
	// Sweep re-decides owners that may have gone stale and sends pushes that were debounced.
	Sweep(ctx context.Context) error
	// Subscribe streams messages for one user's Mac connection; unsubscribe reports whether it was the last.
	Subscribe(userID string) (updates <-chan Message, unsubscribe func() (last bool))
	// NotifySkinChanged tells the user's Macs and iPhone widgets to fetch the account's skin again.
	NotifySkinChanged(userID string)
}

type presenceService struct {
	txRepo        tx.TxRepo
	presenceRepo  repoPresence.PresenceRepo
	deviceService device.DeviceService
	friendService friend.FriendService
	apns          *apns.Client // nil when APNs isn't configured: no pushes
	hub           *hub
}

func NewPresenceService(
	txRepo tx.TxRepo,
	presenceRepo repoPresence.PresenceRepo,
	deviceService device.DeviceService,
	friendService friend.FriendService,
	apnsClient *apns.Client,
) PresenceService {
	return &presenceService{
		txRepo:        txRepo,
		presenceRepo:  presenceRepo,
		deviceService: deviceService,
		friendService: friendService,
		apns:          apnsClient,
		hub:           newHub(),
	}
}
