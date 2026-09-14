package skin

import (
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"

	"github.com/gofiber/fiber/v2"
)

// List returns the skins the account was granted; the built-in skin ships in the apps and isn't listed.
func (h *SkinHandler) List(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	resultData, err := h.skinService.List(c.Context(), userID)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// Archive sends a granted skin's zip. Caches must revalidate (ETag is the sha256), so a revoked grant stops
// serving it right away.
func (h *SkinHandler) Archive(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	skin, err := h.skinService.GetArchive(c.Context(), userID, c.Params("id"))
	if err != nil {
		return errors.Respond(c, err)
	}

	etag := `"` + skin.SHA256 + `"`
	c.Set(fiber.HeaderETag, etag)
	c.Set(fiber.HeaderCacheControl, "private, no-cache")
	if c.Get(fiber.HeaderIfNoneMatch) == etag {
		return c.SendStatus(fiber.StatusNotModified)
	}
	c.Set(fiber.HeaderContentType, "application/zip")
	return c.Status(fiber.StatusOK).Send(skin.Archive)
}
