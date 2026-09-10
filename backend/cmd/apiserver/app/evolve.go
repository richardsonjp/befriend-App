package app

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"befriend/cmd/apiserver/app/store"
	"befriend/config"
)

// Evolve runs the hourly maintenance job once (a cron job calls `apiserver evolve`): delete activity older than
// 30 days and expired pairing codes, queue every friend whose weekly evolution is due, and generate what the
// LLM budget allows.
func Evolve() {
	loc, err := time.LoadLocation(config.Config.System.TimeZone)
	if err != nil {
		panic("Invalid timezone: " + config.Config.System.TimeZone)
	}
	time.Local = loc
	store.Init()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	summary, err := store.App.EvolutionService.Run(ctx)
	fmt.Printf("evolve: deleted %d events and %d pairing codes, queued %d evolutions, generated %d personalities\n",
		summary.EventsDeleted, summary.PairingCodesDeleted, summary.Queued, summary.Generated)
	if err != nil {
		fmt.Fprintln(os.Stderr, "evolve failed:", err)
		os.Exit(1)
	}
}
