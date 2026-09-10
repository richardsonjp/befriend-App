package onboarding

import (
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"

	"github.com/gofiber/fiber/v2"
)

func (h *OnboardingHandler) GetQuestions(c *fiber.Ctx) error {
	resultData, err := h.onboardingService.GetQuestions(c.Context())
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Data: resultData,
	})
}
