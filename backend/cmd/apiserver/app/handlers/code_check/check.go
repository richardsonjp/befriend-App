package code_check

import (
	serviceCodeCheck "befriend/internal/services/code_check"
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/validator"

	"github.com/gofiber/fiber/v2"
)

// Check compiles a code answer on Compiler Explorer and, when asked, runs it once there (M40).
func (h *CodeCheckHandler) Check(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	payload := new(serviceCodeCheck.CheckPayload)
	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}
	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}
	payload.UserID = userID
	result, err := h.codeCheckService.Check(c.Context(), *payload)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: result})
}
