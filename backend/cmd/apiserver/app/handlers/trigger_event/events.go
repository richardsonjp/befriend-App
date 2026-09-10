package trigger_event

import (
	serviceTriggerEvent "befriend/internal/services/trigger_event"
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/validator"

	"github.com/gofiber/fiber/v2"
)

// Record accepts a batch of up to 200 events from the signed-in device; re-sending a batch is harmless.
func (h *TriggerEventHandler) Record(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	deviceID, _ := c.Locals("device_id").(string)

	payload := new(serviceTriggerEvent.RecordPayload)
	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}
	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}
	payload.UserID = userID
	payload.DeviceID = deviceID

	resultData, err := h.triggerEventService.Record(c.Context(), *payload)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// DeleteAll deletes the signed-in user's synced activity.
func (h *TriggerEventHandler) DeleteAll(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	if err := h.triggerEventService.DeleteAll(c.Context(), userID); err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Message: "success"})
}
