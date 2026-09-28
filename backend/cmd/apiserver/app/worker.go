package app

import (
	"context"
	"time"

	"befriend/config"
	"befriend/internal/services/presence"
	"befriend/internal/services/skin"
	"befriend/pkg/clients/db"
	"befriend/pkg/utils/logs"
)

const defaultWorkerInterval = 10 * time.Second

// runPresenceSweeper re-decides owners whose Mac went quiet or whose phone claim lapsed, and sends pushes that
// were debounced.
func runPresenceSweeper(ctx context.Context, service presence.PresenceService) {
	interval := time.Duration(config.Config.Presence.SweepIntervalSec) * time.Second
	runEvery(ctx, interval, "presence sweeper", service.Sweep)
}

// runSkinListener relays skin_changed notifications to the user's Macs and iPhone widgets. They come from settings
// changes here and from `apiserver skin publish|grant|revoke`, which runs as another process.
func runSkinListener(ctx context.Context, service presence.PresenceService) {
	db.Listen(ctx, skin.NotifyChannel, func(userID string) {
		defer func() {
			if r := recover(); r != nil {
				logs.Log.Errorf("skin listener panic: %v", r)
			}
		}()
		service.NotifySkinChanged(userID)
	})
}

// runEvery calls pass on a ticker until ctx is cancelled. Each pass is panic-safe, so one bad job can't take
// down the API.
func runEvery(ctx context.Context, interval time.Duration, name string, pass func(context.Context) error) {
	if interval <= 0 {
		interval = defaultWorkerInterval
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			func() {
				defer func() {
					if r := recover(); r != nil {
						logs.Log.Errorf("%s panic: %v", name, r)
					}
				}()
				if err := pass(ctx); err != nil && ctx.Err() == nil {
					logs.Log.Errorf("%s: %v", name, err)
				}
			}()
		}
	}
}
