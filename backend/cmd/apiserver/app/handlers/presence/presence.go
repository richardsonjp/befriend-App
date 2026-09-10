package presence

import (
	"context"
	"time"

	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/logs"

	"github.com/gofiber/contrib/websocket"
	"github.com/gofiber/fiber/v2"
)

const (
	// socketReadTimeout: the Mac heartbeats every 30 seconds; a connection silent for longer is dead.
	socketReadTimeout = 100 * time.Second
	// socketWriteTimeout keeps a vanished client (no FIN) from blocking the writer forever.
	socketWriteTimeout = 10 * time.Second
)

func (h *PresenceHandler) Get(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	resultData, err := h.presenceService.Get(c.Context(), userID)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// Claim is the iPhone app in the foreground: the friend comes to the phone.
func (h *PresenceHandler) Claim(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	resultData, err := h.presenceService.ClaimPhone(c.Context(), userID)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

func (h *PresenceHandler) Release(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	resultData, err := h.presenceService.ReleasePhone(c.Context(), userID)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// RequireUpgrade rejects plain HTTP requests to the socket route.
func (h *PresenceHandler) RequireUpgrade(c *fiber.Ctx) error {
	if websocket.IsWebSocketUpgrade(c) {
		return c.Next()
	}
	return errors.Respond(c, errors.From("BAD_REQUEST").WithDetail("WebSocket upgrade required"))
}

type socketMessage struct {
	Active bool `json:"active"`
}

type ownerMessage struct {
	Owner string `json:"owner"`
}

// Socket is the Mac's presence connection: it sends {"active": bool} on change and every 30 seconds, and receives
// {"owner": "phone"|"mac"} now and whenever the owner changes.
func (h *PresenceHandler) Socket() fiber.Handler {
	return websocket.New(func(conn *websocket.Conn) {
		userID, _ := conn.Locals("user_id").(string)
		if userID == "" {
			return
		}
		ctx := context.Background()
		updates, unsubscribe := h.presenceService.Subscribe(userID)

		// Only this goroutine writes to the connection.
		done := make(chan struct{})
		writerDone := make(chan struct{})
		write := func(owner string) error {
			_ = conn.SetWriteDeadline(time.Now().Add(socketWriteTimeout))
			return conn.WriteJSON(ownerMessage{Owner: owner})
		}
		go func() {
			defer close(writerDone)
			if state, err := h.presenceService.Get(ctx, userID); err == nil && write(string(state.Owner)) != nil {
				return
			}
			for {
				select {
				case owner := <-updates:
					if write(string(owner)) != nil {
						return
					}
				case <-done:
					return
				}
			}
		}()

		var lastHeartbeat time.Time
		for {
			_ = conn.SetReadDeadline(time.Now().Add(socketReadTimeout))
			var msg socketMessage
			if err := conn.ReadJSON(&msg); err != nil {
				break
			}
			if err := h.presenceService.MacHeartbeat(ctx, userID, msg.Active); err != nil {
				logs.Log.Errorf("presence heartbeat %s: %v", userID, err)
			}
			// After the write: mac_seen_at is stamped inside it, so only a later connection's beat is newer.
			lastHeartbeat = time.Now()
		}

		close(done)
		_ = conn.Close() // unblocks a write stuck on a dead peer
		<-writerDone
		if unsubscribe() {
			if err := h.presenceService.MacDisconnected(ctx, userID, lastHeartbeat); err != nil {
				logs.Log.Errorf("presence disconnect %s: %v", userID, err)
			}
		}
	})
}
