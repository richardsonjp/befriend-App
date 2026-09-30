package chat_sync

import (
	"strings"

	serviceChatSync "befriend/internal/services/chat_sync"
	"befriend/pkg/utils/api"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/validator"

	"github.com/gofiber/fiber/v2"
)

// GetKey returns the id of the user's chat sync key, or null before any device set one.
func (h *ChatSyncHandler) GetKey(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	resultData, err := h.chatSyncService.GetKey(c.Context(), userID)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// SetKey claims the key id for the user; 409 CHAT_KEY_MISMATCH when another one is already set.
func (h *ChatSyncHandler) SetKey(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	payload := new(serviceChatSync.KeyPayload)
	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}
	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}
	payload.UserID = userID

	resultData, err := h.chatSyncService.SetKey(c.Context(), *payload)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// ListRecords pulls the user's records changed after ?after= (a seq), ?limit= at a time.
func (h *ChatSyncHandler) ListRecords(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	payload := new(serviceChatSync.ListRecordsPayload)
	if err := c.QueryParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}
	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}
	payload.UserID = userID

	resultData, err := h.chatSyncService.ListRecords(c.Context(), *payload)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// PutRecord uploads one encrypted record (or its tombstone); the later modified_at wins.
func (h *ChatSyncHandler) PutRecord(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	payload := new(serviceChatSync.RecordPayload)
	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}
	payload.Kind = c.Params("kind")
	payload.ID = strings.ToLower(c.Params("id")) // Swift writes UUIDs uppercase
	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}
	payload.UserID = userID

	resultData, err := h.chatSyncService.PutRecord(c.Context(), *payload)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// PutExchange creates or fills in a key exchange between the user's Mac and iPhone.
func (h *ChatSyncHandler) PutExchange(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	payload := new(serviceChatSync.ExchangePayload)
	if err := c.BodyParser(payload); err != nil {
		return errors.Respond(c, errors.From("BAD_REQUEST"))
	}
	payload.ID = strings.ToLower(c.Params("id"))
	if errMessage, err := validator.Validate(payload); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}
	payload.UserID = userID

	resultData, err := h.chatSyncService.PutExchange(c.Context(), *payload)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}

// GetExchange polls a key exchange; 404 CHAT_EXCHANGE_NOT_FOUND when missing or expired.
func (h *ChatSyncHandler) GetExchange(c *fiber.Ctx) error {
	userID, ok := c.Locals("user_id").(string)
	if !ok {
		return errors.Respond(c, errors.From("UNAUTHORIZED"))
	}
	id := strings.ToLower(c.Params("id"))
	if errMessage, err := validator.Validate(struct {
		ID string `validate:"required,uuid"`
	}{id}); err != nil {
		return errors.Respond(c, errors.From("VALIDATION_FAILED").WithDetail(errMessage))
	}

	resultData, err := h.chatSyncService.GetExchange(c.Context(), userID, id)
	if err != nil {
		return errors.Respond(c, err)
	}
	return c.Status(fiber.StatusOK).JSON(api.Base{Data: resultData})
}
