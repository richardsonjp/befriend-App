package user

import (
	"go-skeleton/internal/services/user_application"
	"go-skeleton/pkg/utils/api"
	"go-skeleton/pkg/utils/errors"
	"go-skeleton/pkg/utils/validator"

	"github.com/gofiber/fiber/v2"
)

func (h *UserHandler) Registration(c *fiber.Ctx) error {
	payload := new(user_application.RegisterPayload)

	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}

	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}

	err := h.userApplicationService.Register(c.Context(), *payload)
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Message: "success",
	})
}
