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

	// Initialize Store (DB, Redis, Repos, Services, Middleware)
	store.Init()

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

	logs.Log.Warn("Server gracefully stopped.")
}
