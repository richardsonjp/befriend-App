package friend

import (
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"

	"github.com/gofiber/fiber/v2"
)

// GetFriend returns the signed-in user's friend; 404 until onboarding is complete.
func (h *FriendHandler) GetFriend(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}

	resultData, err := h.friendService.GetProfile(c.Context(), userID)
	if err != nil {
		return errors.Respond(c, err)
	}

	return c.Status(fiber.StatusOK).JSON(api.Base{
		Data: resultData,
	})
}
