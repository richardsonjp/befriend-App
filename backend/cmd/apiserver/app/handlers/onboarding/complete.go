package onboarding

import (
	"befriend/internal/services/onboarding"
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/validator"

	"github.com/gofiber/fiber/v2"
)

func (h *OnboardingHandler) Complete(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}

	payload := new(onboarding.CompletePayload)

	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}

	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}

	resultData, err := h.onboardingService.Complete(c.Context(), userID, *payload)
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Data: resultData,
	})
}
