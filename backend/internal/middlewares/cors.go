package middlewares

import "github.com/gofiber/fiber/v2"

func Cors() fiber.Handler {
	return func(c *fiber.Ctx) error {
		c.Set("Access-Control-Allow-Origin", "*")
		c.Set("Access-Control-Allow-Credentials", "true")
		c.Set("Access-Control-Allow-Headers", "Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization, accept, origin, Cache-Control, X-Requested-With, STATIC-API-KEY")
		c.Set("Access-Control-Allow-Methods", "POST, OPTIONS, GET, PUT, DELETE")

		if c.Method() == "OPTIONS" {
			return c.SendStatus(204)
		}

		return c.Next()
	}
}
