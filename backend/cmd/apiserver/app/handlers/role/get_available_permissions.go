package role

import (
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"

	"github.com/gofiber/fiber/v2"
)

func (h *RoleHandler) GetAvailablePermissions(c *fiber.Ctx) error {
	result, err := h.roleService.GetAvailablePermissions(c.Context())
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Data: result,
	})
}
