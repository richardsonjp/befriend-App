package user_auth

import (
	"befriend/internal/services/authentication"
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"

	"github.com/gofiber/fiber/v2"
)

func (h *UserAuthHandler) Logout(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	deviceID, ok := c.Locals("device_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}

	err := h.authenticationService.AuthenticateLogout(c.Context(), authentication.LogoutPayload{
		UserID:   userID,
		DeviceID: deviceID,
	})
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Message: "success",
	})
}
