package user

import (
	"go-skeleton/internal/services/user_application"
	"go-skeleton/pkg/utils/api"
	"go-skeleton/pkg/utils/errors"
	"go-skeleton/pkg/utils/validator"

	"github.com/gofiber/fiber/v2"
)

func (h *UserHandler) VerifyEmail(c *fiber.Ctx) error {
	payload := new(user_application.VerifyEmailPayload)

	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}

	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}

	err := h.userApplicationService.VerifyUserEmail(c.Context(), *payload)
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Message: "success",
	})
}
