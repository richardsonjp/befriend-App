package user_auth

import (
	"go-skeleton/internal/services/authentication"
	"go-skeleton/pkg/utils/api"
	"go-skeleton/pkg/utils/errors"
	"go-skeleton/pkg/utils/validator"

	"github.com/gofiber/fiber/v2"
)

func (h *UserAuthHandler) Login(c *fiber.Ctx) error {
	payload := new(authentication.Login)

	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}

	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}

	resultData, err := h.authenticationService.AuthenticateUser(c.Context(), *payload)
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Data: resultData,
	})
}
