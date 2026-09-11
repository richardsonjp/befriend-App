package middlewares

import (
	"time"

	"befriend/pkg/utils/errors"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/limiter"
)

// RateLimit allows max requests per minute per client IP, counted separately for each route.
// Routes are keyed by their pattern (/api/pairing/:code), so varying a path parameter doesn't reset the count.
// Client IP honours SYSTEM_PROXY_HEADER (set it only behind a proxy that overwrites that header).
// ponytail: in-memory counters assume one API instance; move them to a shared store (e.g. a Postgres table) when scaling out.
func RateLimit(max int) fiber.Handler {
	return limiter.New(limiter.Config{
		Max:        max,
		Expiration: time.Minute,
		KeyGenerator: func(c *fiber.Ctx) string {
			return c.IP() + "|" + c.Method() + " " + c.Route().Path
		},
		LimitReached: func(c *fiber.Ctx) error {
			return errors.Respond(c, errors.From("TOO_MANY_REQUESTS"))
		},
	})
}
