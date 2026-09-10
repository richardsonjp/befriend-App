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
	roleID, ok := c.Locals("role_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}

	session := authentication.LogoutPayload{
		UserID: userID,
		RoleID: roleID,
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{Data: session})

	err := h.authenticationService.AuthenticateLogout(c.Context(), session)
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Message: "success",
	})
}
