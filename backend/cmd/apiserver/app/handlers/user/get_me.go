package user

import (
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"

	"github.com/gofiber/fiber/v2"
)

func (h *UserHandler) GetMe(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}

	resultData, err := h.userApplicationService.GetMe(c.Context(), userID)
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Data: resultData,
	})
}
