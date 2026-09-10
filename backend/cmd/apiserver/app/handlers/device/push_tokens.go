package device

import (
	serviceDevice "befriend/internal/services/device"
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/validator"

	"github.com/gofiber/fiber/v2"
)

// UpdatePushTokens stores the signed-in device's APNs tokens. Omitted tokens are left as they are; an empty
// string clears one.
func (h *DeviceHandler) UpdatePushTokens(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	deviceID, ok := c.Locals("device_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}

	payload := new(serviceDevice.PushTokensPayload)
	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}
	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}
	payload.UserID = userID
	payload.DeviceID = deviceID

	if err := h.deviceService.UpdatePushTokens(c.Context(), *payload); err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{
		Message: "success",
	})
}
