package app

import (
	"context"
	"time"

	"befriend/config"
	"befriend/internal/services/personality"
	"befriend/pkg/utils/logs"
)

const defaultWorkerInterval = 10 * time.Second

// runPersonalityWorker drains the personality generation queue until ctx is cancelled. Each pass is
// panic-safe, so one bad job can't take down the API.
func runPersonalityWorker(ctx context.Context, service personality.PersonalityService) {
	interval := time.Duration(config.Config.LLM.WorkerIntervalSec) * time.Second
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
						logs.Log.Errorf("personality worker panic: %v", r)
					}
				}()
				if _, err := service.ProcessDue(ctx, config.Config.LLM.BatchSize); err != nil && ctx.Err() == nil {
					logs.Log.Errorf("personality worker: %v", err)
				}
			}()
		}
	}
}
