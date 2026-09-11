package app

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"befriend/cmd/apiserver/app/routes"
	"befriend/cmd/apiserver/app/store"
	"befriend/config"
	"befriend/pkg/utils/logs"

	"github.com/shopspring/decimal"
)

func Run() {
	// Load timezone
	loc, err := time.LoadLocation(config.Config.System.TimeZone)
	if err != nil {
		panic("Invalid timezone: " + config.Config.System.TimeZone)
	}
	time.Local = loc

	// JSON decimal output without quotes
	decimal.MarshalJSONWithoutQuotes = true

	// Init global logger
	logs.Init("")

	// Initialize Store (DB, Repos, Services, Middleware)
	store.Init()

	// Generate personalities in the background (queue: personality_version)
	workerCtx, stopWorker := context.WithCancel(context.Background())
	defer stopWorker()
	workerDone := make(chan struct{})
	go func() {
		defer close(workerDone)
		runPersonalityWorker(workerCtx, store.App.PersonalityService)
	}()
	go runPresenceSweeper(workerCtx, store.App.PresenceService)

	// Start fiber
	app := routes.NewHTTPServer(store.App)

	// Start server async
	go func() {
		logs.Log.Infof("[Server:Addr]: %s", config.Config.System.AppAddr)

		if err := app.Listen(config.Config.System.AppAddr); err != nil {
			logs.Log.Errorf("Server stopped: %v", err)
		}
	}()

	// Wait for Ctrl+C
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logs.Log.Warn("Shutdown signal received...")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := app.ShutdownWithContext(ctx); err != nil {
		logs.Log.Errorf("Graceful shutdown error: %v", err)
	}

	// Let an in-flight personality job record its outcome (it is deferred, not failed).
	stopWorker()
	select {
	case <-workerDone:
	case <-ctx.Done():
		logs.Log.Warn("Personality worker did not stop in time; its job unlocks after the claim expires")
	}

	logs.Log.Warn("Server gracefully stopped.")
}
