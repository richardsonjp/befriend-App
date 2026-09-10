package operator_auth

import (
	"go-skeleton/pkg/utils/api"

	"github.com/gofiber/fiber/v2"
)

func (h *OperatorAuthHandler) Logout(c *fiber.Ctx) error {

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Message: "success",
	})
}
