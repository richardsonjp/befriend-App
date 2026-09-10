package user_auth

import (
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"

	"github.com/gofiber/fiber/v2"
)

// DeleteAccount permanently deletes the signed-in user's account.
func (h *UserAuthHandler) DeleteAccount(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}

	if err := h.authenticationService.DeleteAccount(c.Context(), userID); err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Message: "success",
	})
}
