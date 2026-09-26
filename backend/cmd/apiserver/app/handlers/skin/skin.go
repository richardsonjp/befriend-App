package skin

import (
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/validator"

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

// Submit takes an invited artist's skin: the zipped skin folder as the body (Content-Type application/zip), and
// the id it should publish under as ?skin_id=. It's checked against the skin format now and published once
// approved.
func (h *SkinHandler) Submit(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	resultData, err := h.skinService.Submit(c.Context(), userID, c.Query("skin_id"), c.Body())
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusCreated).JSON(api.Base{Data: resultData})
}

// Submissions lists the artist's own submissions and how they were reviewed.
func (h *SkinHandler) Submissions(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	resultData, err := h.skinService.ListSubmissions(c.Context(), &userID)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// Catalog lists the skins for sale (with their App Store product ids and a preview) and which the account owns.
func (h *SkinHandler) Catalog(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	resultData, err := h.skinService.Catalog(c.Context(), userID)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

type purchasePayload struct {
	SignedTransaction string `json:"signed_transaction" validate:"required,max=20000"`
}

// Purchase unlocks a skin bought in the app: the body carries StoreKit's signed transaction (jwsRepresentation).
// Restoring purchases sends each one again; that's idempotent.
func (h *SkinHandler) Purchase(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	var payload purchasePayload
	if err := c.BodyParser(&payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}
	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST").WithDetail(errMessage))
	}
	resultData, err := h.skinService.Purchase(c.Context(), userID, payload.SignedTransaction)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// AppStoreNotification receives App Store Server Notifications v2 ({"signedPayload": …}); Apple retries anything
// but a 2xx.
func (h *SkinHandler) AppStoreNotification(c *fiber.Ctx) error {
	var payload struct {
		SignedPayload string `json:"signedPayload"`
	}
	if err := c.BodyParser(&payload); err != nil || payload.SignedPayload == "" {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}
	if err := h.skinService.AppStoreNotification(c.Context(), payload.SignedPayload); err != nil {
		return errors.Respond(c, err)
	}
	return c.SendStatus(fiber.StatusOK)
}
