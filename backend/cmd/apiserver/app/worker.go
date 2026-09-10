package app

import (
	"context"
	"time"

	"befriend/config"
	"befriend/internal/services/personality"
	"befriend/internal/services/presence"
	"befriend/pkg/utils/logs"
)

const defaultWorkerInterval = 10 * time.Second

// runPersonalityWorker drains the personality generation queue until ctx is cancelled.
func runPersonalityWorker(ctx context.Context, service personality.PersonalityService) {
	interval := time.Duration(config.Config.LLM.WorkerIntervalSec) * time.Second
	runEvery(ctx, interval, "personality worker", func(ctx context.Context) error {
		_, err := service.ProcessDue(ctx, config.Config.LLM.BatchSize)
		return err
	})
}

// runPresenceSweeper re-decides owners whose Mac went quiet or whose phone claim lapsed, and sends pushes that
// were debounced.
func runPresenceSweeper(ctx context.Context, service presence.PresenceService) {
	interval := time.Duration(config.Config.Presence.SweepIntervalSec) * time.Second
	runEvery(ctx, interval, "presence sweeper", service.Sweep)
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
