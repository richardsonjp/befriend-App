package friend

import (
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"

	"github.com/gofiber/fiber/v2"
)

// Hatch writes the friend's first personality while the app waits (usually under a minute, up to several) and
// returns the friend, ready. On failure nothing retries by itself: the app shows the error and Try again.
func (h *FriendHandler) Hatch(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}

	if err := h.personalityService.Hatch(c.Context(), userID); err != nil {
		return errors.Respond(c, err)
	}
	resultData, err := h.friendService.GetProfile(c.Context(), userID)
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Data: resultData,
	})
}
