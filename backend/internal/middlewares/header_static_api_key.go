package middlewares

import (
	"befriend/config"
	"befriend/pkg/utils/errors"

	"github.com/gofiber/fiber/v2"
)

// CheckHeaderStaticApiKey validates the STATIC-API-KEY header
func CheckHeaderStaticApiKey() fiber.Handler {
	return func(c *fiber.Ctx) error {
		token := c.Get("STATIC-API-KEY")
		if token == "" {
			return errors.Respond(c,
				errors.From("UNAUTHORIZED").WithDetail("STATIC-API-KEY header missing"),
			)
		}

		keys := config.Config.MiddlewareKeys
		if token != keys.StaticAPIKey {
			return errors.Respond(c,
				errors.From("UNAUTHORIZED").WithDetail("Invalid STATIC-API-KEY"),
			)
		}

		return c.Next()
	}
}
