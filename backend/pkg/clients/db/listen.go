package db

import (
	"context"
	"time"

	"befriend/pkg/utils/logs"

	"github.com/jackc/pgx/v5"
)

const maxListenBackoff = 30 * time.Second

// Listen calls handle with the payload of every NOTIFY on channel until ctx is done. It holds its own connection,
// outside the GORM pool, and reconnects with backoff (1 s doubling to 30 s) when that connection drops.
// ponytail: notifications sent while reconnecting are lost; the apps also re-check on launch and foreground.
func Listen(ctx context.Context, channel string, handle func(payload string)) {
	backoff := time.Second
	for {
		err := listenOnce(ctx, channel, handle, func() { backoff = time.Second })
		if ctx.Err() != nil {
			return
		}
		logs.Log.Errorf("listen %s: %v (reconnecting in %s)", channel, err, backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, maxListenBackoff)
	}
}

func listenOnce(ctx context.Context, channel string, handle func(string), connected func()) error {
	conn, err := pgx.Connect(ctx, dbSource(true))
	if err != nil {
		return err
	}
	defer conn.Close(context.Background())

	if _, err := conn.Exec(ctx, "LISTEN "+pgx.Identifier{channel}.Sanitize()); err != nil {
		return err
	}
	connected()
	for {
		notification, err := conn.WaitForNotification(ctx)
		if err != nil {
			return err
		}
		handle(notification.Payload)
	}
}
