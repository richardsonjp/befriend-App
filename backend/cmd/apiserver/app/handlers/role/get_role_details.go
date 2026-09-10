package role

import (
	"go-skeleton/pkg/utils/api"
	"go-skeleton/pkg/utils/errors"

	"github.com/gofiber/fiber/v2"
)

func (h *RoleHandler) GetRoleDetails(c *fiber.Ctx) error {
	roleID := c.Params("id")

	result, err := h.roleService.GetRoleDetails(c.Context(), roleID)
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Data: result,
	})
}
