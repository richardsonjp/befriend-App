package middlewares

import (
	"go-skeleton/config"
	"go-skeleton/pkg/utils/errors"
	"go-skeleton/pkg/utils/paseto"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// MiddlewarePasetoAuth validates the PASETO access token
func (MiddlewarePasetoAuth) MiddlewarePasetoAuth(c *fiber.Ctx) error {
	authHeader := c.Get("Authorization")
	if authHeader == "" {
		return errors.Respond(c, errors.From("UNAUTHORIZED").WithDetail("Missing Authorization header"))
	}

	tokenString := strings.TrimPrefix(authHeader, "Bearer ")
	if tokenString == authHeader {
		return errors.Respond(c, errors.From("UNAUTHORIZED").WithDetail("Invalid Authorization header format"))
	}

	claims, err := paseto.ValidateToken(tokenString, config.Config.PASETO.AccessSecret)
	if err != nil {
		return errors.Respond(c, errors.From("UNAUTHORIZED").WithDetail("Invalid or expired token"))
	}

	// Set user context
	c.Locals("user_id", claims.UserID)
	c.Locals("role_id", claims.RoleID)

	return c.Next()
}
