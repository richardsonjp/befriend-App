package pairing

import (
	"befriend/internal/services/pairing_code"
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/validator"

	"github.com/gofiber/fiber/v2"
)

// Create starts a pairing for a signed-out Mac (public).
func (h *PairingHandler) Create(c *fiber.Ctx) error {
	payload := new(pairing_code.CreatePayload)
	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}
	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}

	resultData, err := h.pairingCodeService.Create(c.Context(), *payload)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// Claim is the Mac's poll (public): 202 while waiting for the iPhone, 200 with the session once, 410 after.
func (h *PairingHandler) Claim(c *fiber.Ctx) error {
	payload := new(pairing_code.ClaimPayload)
	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}
	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}

	resultData, err := h.authenticationService.ClaimPairing(c.Context(), *payload)
	if err != nil {
		return errors.Respond(c, err)
	}
	if resultData == nil {
		return c.Status(fiber.StatusAccepted).JSON(api.Base{Data: fiber.Map{"status": "pending"}})
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// Get describes a scanned code to the signed-in iPhone before it confirms.
func (h *PairingHandler) Get(c *fiber.Ctx) error {
	if _, ok := c.Locals("user_id").(string); !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	resultData, err := h.pairingCodeService.GetPending(c.Context(), c.Params("code"))
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// Confirm links the scanned code to the signed-in iPhone's account.
func (h *PairingHandler) Confirm(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	if err := h.pairingCodeService.Confirm(c.Context(), c.Params("code"), userID); err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Message: "success"})
}
